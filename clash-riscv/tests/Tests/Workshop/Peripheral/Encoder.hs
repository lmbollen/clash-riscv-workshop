{- | Tests for the Pmod ENC peripheral in "Workshop.Peripheral.Encoder".

Three layers, cheapest first:

  * 'quadratureDelta' and 'debounce' are ordinary functions, so they are tested
    directly against the behaviour their documentation promises.

  * 'rotaryEncoder' is tested through its Wishbone port, the way the CPU sees it:
    a pin waveform is played into the device, and once it has settled the
    registers are read back over a real bus. That covers the decoder, the
    register wiring (which register ended up at which address) and the access
    rights in one go.

The bus side uses the driver from @clash-protocols@' Wishbone test kit rather
than a hand-rolled master, so the transactions the device sees are properly
handshaken, and 'validatorCircuit' fails the test if the device replies in a way
the Wishbone spec does not allow.
-}
module Tests.Workshop.Peripheral.Encoder where

import Prelude

import Control.Monad (forM_)
import Test.Tasty
import Test.Tasty.Hedgehog
import Test.Tasty.TH

import qualified Clash.Prelude as C
import qualified Hedgehog as H
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range

import Clash.Class.BitPackC (BitPackC, ByteOrder (LittleEndian))
import Clash.Class.BitPackC.Words (SizeInWordsC, unpackWordOrErrorCI)
import Data.Typeable (Typeable)
import Protocols (Circuit, (|>))
import Protocols.Experimental.Hedgehog (ExpectOptions (..), defExpectOptions)
import Protocols.Experimental.Wishbone (Wishbone, WishboneMode (Standard), WishboneS2M (..))
import Protocols.Experimental.Wishbone.Standard.Hedgehog (
  WishboneMasterRequest (..),
  driveStandard,
  validatorCircuit,
 )
import Protocols.MemoryMap (unMemmap)

import qualified Protocols.Experimental.Wishbone.Standard.Hedgehog as Wb

import qualified Workshop.Peripheral.Encoder as Enc
import Workshop.Peripheral.Encoder (
  EncoderPins (..),
  debounce,
  idleEncoderPins,
  quadratureDelta,
  rotaryEncoder,
 )

-- * The device under test

-- | Wide enough for the three registers, with room to spare for the miss test.
type AddressWidth = 4

-- | Four-byte bus words, as in the SoC.
type WordSize = 4

{- | How many values @position@ can take.

Re-exported from the peripheral rather than restated here. These two were once
separate numbers that disagreed, and the resulting three failing properties said
nothing about the hardware.
-}
type Positions = Enc.Positions

{- | Word addresses of the three registers, in the order 'rotaryEncoder'
instantiates them. 'deviceWb' lays registers out back to back from offset zero,
and all three of these fit in a single bus word.
-}
positionAddr, buttonAddr, switchAddr, unmappedAddr :: C.BitVector AddressWidth
positionAddr = 0
buttonAddr = 1
switchAddr = 2
unmappedAddr = 3

-- | Debounce length used in the tests: long enough to be a real filter, short
-- enough that a simulation can sit through it several times over.
type TestDebounceCycles = 8

testDebounceCycles :: Int
testDebounceCycles = C.natToNum @TestDebounceCycles

-- * Bus harness

{- | Play @pinWaveform@ into 'rotaryEncoder' with the bus idle, then -- once the
waveform has run out and its last value is being held -- issue @requests@ and
return the response to each, in order.

Keeping the two phases apart is what makes the tests readable: every response
below describes a settled device, so no test has to reason about which bus cycle
lines up with which pin transition.
-}
runEncoder ::
  [EncoderPins] ->
  [WishboneMasterRequest AddressWidth WordSize] ->
  [WishboneS2M WordSize]
runEncoder pinWaveform requests =
  [s2m | (_m2s, s2m) <- Wb.sample opts master slave, terminated s2m]
 where
  -- A couple of cycles on top of the waveform for the input synchronisers and
  -- the register update to work through.
  settleCycles = length pinWaveform + 4

  opts =
    defExpectOptions
      { -- The driver holds off for this long before its first request, which is
        -- exactly the quiet period the waveform needs.
        eoResetCycles = settleCycles
      , eoSampleMax = settleCycles + 100 * (1 + length requests)
      }

  master = driveStandard opts [(request, 0) | request <- requests]

  slave :: Circuit (Wishbone C.System 'Standard AddressWidth WordSize) ()
  slave =
    C.withClockResetEnable C.clockGen C.resetGen C.enableGen
      $ let ?byteOrder = LittleEndian
         in validatorCircuit |> unMemmap (rotaryEncoder (C.SNat @TestDebounceCycles) (C.SNat @Positions) pins)

  -- The pins keep their final value forever, so the reads all see the same
  -- state no matter how long the driver takes to get through them.
  pins = C.fromList (pinWaveform ++ repeat (last (idleEncoderPins : pinWaveform)))

  terminated s2m = acknowledge s2m || err s2m

-- | Read the given register once, after playing in a pin waveform.
readReg ::
  [EncoderPins] -> C.BitVector AddressWidth -> WishboneS2M WordSize
readReg pinWaveform addr = case runEncoder pinWaveform [Read addr maxBound] of
  [s2m] -> s2m
  responses -> error ("expected exactly one response, got " <> show (length responses))

-- | Decode a bus word the way the generated HAL does.
unpackReg ::
  (BitPackC a, C.NFDataX a, Typeable a, SizeInWordsC WordSize a ~ 1) =>
  WishboneS2M WordSize ->
  a
unpackReg s2m = let ?byteOrder = LittleEndian in unpackWordOrErrorCI (readData s2m C.:> C.Nil)

-- * Pin stimulus

{- | The @(A, B)@ states in the order a clockwise turn visits them, matching the
cycle 'quadratureDelta' documents. 'rotaryEncoder' packs the pins as @(A, B)@,
so A is the high bit.
-}
quadratureCycle :: C.Vec 4 (C.BitVector 2)
quadratureCycle = 0b00 C.:> 0b01 C.:> 0b11 C.:> 0b10 C.:> C.Nil

-- | The two quadrature pins set to a state from 'quadratureCycle', everything
-- else at rest.
abPins :: C.BitVector 2 -> EncoderPins
abPins ab = idleEncoderPins{encA = C.msb ab, encB = C.lsb ab}

{- | A pin waveform for a sequence of turns, each given in quadrature edges and
picking up where the previous one left off. Positive is clockwise.

Each state is held for @dwell@ cycles; the waveform starts from the rest state
@00@, which is also what the decoder comes out of reset assuming, so there is no
phantom edge at time zero.
-}
walk :: Int -> [Int] -> [EncoderPins]
walk dwell turns =
  concatMap (replicate dwell . abPins . state) (scanl (+) 0 (concatMap edges turns))
 where
  edges n = replicate (abs n) (signum n)
  state i = quadratureCycle C.!! (i `mod` 4)

-- | 'walk' for a single turn.
turn :: Int -> Int -> [EncoderPins]
turn dwell edges = walk dwell [edges]

-- | The button and/or switch held down long enough to make it through the
-- debounce filter, with the shaft still.
holdContacts :: Bool -> Bool -> [EncoderPins]
holdContacts button switch =
  replicate (2 * testDebounceCycles + 8)
    idleEncoderPins
      { encBtn = C.boolToBit button
      , encSwt = C.boolToBit switch
      }

-- * 'quadratureDelta'

-- | Every step around the Gray cycle is one edge: forwards @+1@, backwards @-1@.
prop_quadratureDeltaFollowsGrayCycle :: H.Property
prop_quadratureDeltaFollowsGrayCycle = H.withTests 1 $ H.property $ do
  let cycle4 = C.toList quadratureCycle
      forwards = zip cycle4 (C.toList (C.rotateLeft quadratureCycle (1 :: Int)))
  forM_ forwards $ \(old, new) -> do
    H.annotateShow (old, new)
    quadratureDelta old new H.=== 1
    quadratureDelta new old H.=== (-1)

-- | A sample where nothing changed is not movement.
prop_quadratureDeltaIgnoresRepeats :: H.Property
prop_quadratureDeltaIgnoresRepeats = H.property $ do
  ab <- H.forAll genAb
  quadratureDelta ab ab H.=== 0

{- | If both channels changed at once a step was missed, and there is no way to
tell which way it went -- so it must report nothing rather than guess.
-}
prop_quadratureDeltaIgnoresDoubleSteps :: H.Property
prop_quadratureDeltaIgnoresDoubleSteps = H.property $ do
  ab <- H.forAll genAb
  quadratureDelta ab (C.complement ab) H.=== 0

-- | Turning back the way you came undoes the step, whatever the transition was.
prop_quadratureDeltaIsAntisymmetric :: H.Property
prop_quadratureDeltaIsAntisymmetric = H.property $ do
  old <- H.forAll genAb
  new <- H.forAll genAb
  quadratureDelta old new H.=== negate (quadratureDelta new old)

genAb :: H.Gen (C.BitVector 2)
genAb = Gen.element [0b00, 0b01, 0b11, 0b10]

-- * 'debounce'

-- | Sample 'debounce' over the 'C.System' domain for the length of its input.
runDebounce :: [Bool] -> [Bool]
runDebounce inp =
  C.sampleN (length inp)
    $ C.withClockResetEnable @C.System C.clockGen C.resetGen C.enableGen
    $ debounce (C.SNat @TestDebounceCycles) (C.fromList (inp ++ repeat (last (False : inp))))

-- | Contact bounce -- a pulse that does not last the full filter length -- never
-- reaches the output.
prop_debounceRejectsShortPulses :: H.Property
prop_debounceRejectsShortPulses = H.property $ do
  before <- H.forAll (Gen.integral (Range.linear 0 8))
  pulse <- H.forAll (Gen.integral (Range.linear 1 (testDebounceCycles - 1)))
  let inp = replicate before False ++ replicate pulse True ++ replicate 40 False
  H.annotateShow inp
  H.assert (not (or (runDebounce inp)))

-- | A level that is held does get through, and then stays.
prop_debouncePassesStableInput :: H.Property
prop_debouncePassesStableInput = H.property $ do
  before <- H.forAll (Gen.integral (Range.linear 0 8))
  let inp = replicate before False ++ replicate (4 * testDebounceCycles) True
      out = runDebounce inp
  H.annotateShow out
  -- It cannot react before the input has been steady for the filter length, and
  -- it must have reacted well before the input ends.
  H.assert (not (or (take (before + testDebounceCycles) out)))
  H.assert (and (drop (before + 3 * testDebounceCycles) out))

-- | The filter starts out low, so a device using it comes up 'not pressed'
-- rather than reading whatever the pin happened to be doing.
prop_debounceStartsLow :: H.Property
prop_debounceStartsLow = H.withTests 1 $ H.property $ do
  take 3 (runDebounce (replicate 20 True)) H.=== [False, False, False]

-- * 'rotaryEncoder'

-- | Out of reset, before anything has been touched, @position@ reads zero.
prop_positionStartsAtZero :: H.Property
prop_positionStartsAtZero = H.withTests 1 $ H.property $ do
  let s2m = readReg [] positionAddr
  err s2m H.=== False
  unpackReg @(C.Index Positions) s2m H.=== 0

-- | Turning the knob clockwise counts up, one per quadrature edge.
prop_positionCountsUpClockwise :: H.Property
prop_positionCountsUpClockwise = H.property $ do
  edges <- H.forAll (Gen.integral (Range.linear 0 (C.natToNum @Positions - 1)))
  dwell <- H.forAll (Gen.integral (Range.linear 1 4))
  let s2m = readReg (turn dwell edges) positionAddr
  err s2m H.=== False
  unpackReg @(C.Index Positions) s2m H.=== fromIntegral edges

-- | Turning it back the other way counts down again, wrapping below zero.
prop_positionCountsDownAnticlockwise :: H.Property
prop_positionCountsDownAnticlockwise = H.property $ do
  edges <- H.forAll (Gen.integral (Range.linear 1 (C.natToNum @Positions - 1)))
  dwell <- H.forAll (Gen.integral (Range.linear 1 4))
  let s2m = readReg (turn dwell (negate edges)) positionAddr
  unpackReg @(C.Index Positions) s2m H.=== fromIntegral (C.natToNum @Positions - edges)

-- | Turning one direction and back leaves the count where it started.
prop_positionRoundTrips :: H.Property
prop_positionRoundTrips = H.property $ do
  edges <- H.forAll (Gen.integral (Range.linear 1 (2 * C.natToNum @Positions)))
  dwell <- H.forAll (Gen.integral (Range.linear 1 3))
  let s2m = readReg (walk dwell [edges, negate edges]) positionAddr
  unpackReg @(C.Index Positions) s2m H.=== 0

-- | Counting past the top wraps back to zero rather than saturating.
prop_positionWrapsAtTheTop :: H.Property
prop_positionWrapsAtTheTop = H.withTests 1 $ H.property $ do
  let s2m = readReg (turn 1 (C.natToNum @Positions)) positionAddr
  unpackReg @(C.Index Positions) s2m H.=== 0

{- | Jiggling the knob on a boundary -- one edge forward, one edge back, over and
over -- must not run the count away in either direction.
-}
prop_positionDoesNotDriftOnJitter :: H.Property
prop_positionDoesNotDriftOnJitter = H.property $ do
  jiggles <- H.forAll (Gen.integral (Range.linear 1 12))
  let s2m = readReg (walk 1 (concat (replicate jiggles [1, -1]))) positionAddr
  unpackReg @(C.Index Positions) s2m H.=== 0

-- | The button and the switch read back independently, and land on the
-- addresses the memory map says they do.
prop_buttonAndSwitchReadBack :: H.Property
prop_buttonAndSwitchReadBack = H.withTests 1 $ H.property $ do
  forM_ [(button, switch) | button <- [False, True], switch <- [False, True]]
    $ \(button, switch) -> do
      H.annotateShow (button, switch)
      let responses =
            runEncoder
              (holdContacts button switch)
              [Read buttonAddr maxBound, Read switchAddr maxBound]
      map (unpackReg @Bool) responses H.=== [button, switch]

-- | All three registers are read-only, so the CPU writing to one is a bus error
-- rather than something that quietly corrupts the reading.
prop_registersRejectWrites :: H.Property
prop_registersRejectWrites = H.withTests 1 $ H.property $ do
  let addrs = [positionAddr, buttonAddr, switchAddr]
      responses = runEncoder [] [Write addr maxBound 0 | addr <- addrs]
  map err responses H.=== map (const True) addrs

-- | Nothing is mapped past the third register, and reading there errors instead
-- of aliasing onto a real one.
prop_unmappedAddressErrors :: H.Property
prop_unmappedAddressErrors = H.withTests 1 $ H.property $ do
  err (readReg [] unmappedAddr) H.=== True

peripheralTests :: TestTree
peripheralTests = $(testGroupGenerator)

main :: IO ()
main = defaultMain peripheralTests
