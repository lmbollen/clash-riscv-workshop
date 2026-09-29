{-# LANGUAGE ImplicitParams #-}

{- | A Wishbone device for a Digilent Pmod ENC: a rotary encoder with a push
button and a slide switch.

The hardware does the parts that need a clock -- synchronising the pins,
debouncing the mechanical contacts, and decoding quadrature into a counter -- and
nothing more. Turning a wrapping counter into a position relative to some chosen
origin is the driver's job; see @firmware/hal/src/drivers/encoder.rs@.
-}
module Workshop.Peripheral.Encoder (
  debounceTop
  ,
  -- * The peripheral
  rotaryEncoder,
  EncoderPins (..),
  idleEncoderPins,

  -- * Sizing
  DebounceCycles,
  Positions,

  -- * Internals, exposed for testing
  quadratureDelta,
  quadratureEncoder,
  debounce,
) where

import Clash.Prelude

import Clash.Class.BitPackC (ByteOrder (..))

import GHC.Stack (HasCallStack)

import Protocols
import Protocols.Experimental.Wishbone
import Protocols.MemoryMap
import Protocols.MemoryMap.Registers.WishboneStandard

-- 'access' is also a field of 'Register', so record updates on 'RegisterConfig'
-- need qualifying to disambiguate.
import qualified Protocols.MemoryMap.Registers.WishboneStandard as Reg

{- | How many values the @position@ register takes before wrapping.

One number, used by "Workshop.Soc" when it instantiates the device and by the
test suite when it exercises it, because the two drifting apart is exactly the
sort of thing that produces a green build and a failing board. The generated PAC
picks it up from the memory map, so the Rust driver tracks it too.
-}
type Positions = 16

{- | The four signals a Digilent Pmod ENC presents. All of them are outputs of
the Pmod, so all of them are inputs here.

The field names carry their own port names, so a top-level
@"ENC" ::: Signal dom EncoderPins@ port flattens to @ENC_A@, @ENC_B@, @ENC_BTN@
and @ENC_SWT@ -- the same trick VexRiscv's @JtagIn@ uses.
-}
data EncoderPins = EncoderPins
  { encA :: "A" ::: Bit
  -- ^ Quadrature channel A.
  , encB :: "B" ::: Bit
  -- ^ Quadrature channel B.
  , encBtn :: "BTN" ::: Bit
  -- ^ The push button in the shaft, high while pressed.
  , encSwt :: "SWT" ::: Bit
  -- ^ The slide switch, high in the on position.
  }
  deriving (Generic, NFDataX, BitPack, ShowX, Eq)

-- | Nothing connected: every line at rest.
idleEncoderPins :: EncoderPins
idleEncoderPins = EncoderPins{encA = low, encB = low, encBtn = low, encSwt = low}

{- | One step of quadrature decoding: how far the shaft moved between two
consecutive @(A, B)@ samples.

The two channels are Gray coded, so exactly one of them changes at a time and the
rest state cycles @00 -> 01 -> 11 -> 10 -> 00@ one way and back the other. A
sample where /both/ changed means a step was missed (the shaft moved faster than
we sampled, or a contact bounced badly); there is no way to tell which way it
went, so report no movement rather than guess a direction.
-}
quadratureDelta :: BitVector 2 -> BitVector 2 -> Signed 2
quadratureDelta old new = case (old, new) of
  (0b00, 0b01) -> 1
  (0b01, 0b11) -> 1
  (0b11, 0b10) -> 1
  (0b10, 0b00) -> 1
  (0b00, 0b10) -> (-1)
  (0b10, 0b11) -> (-1)
  (0b11, 0b01) -> (-1)
  (0b01, 0b00) -> (-1)
  -- Unchanged, or both channels moved at once.
  _ -> 0

{-# OPAQUE quadratureDelta #-}


debounceTop = exposeClockResetEnable @System $ debounce d16

{- | Hold @out@ until @inp@ has read the other way for @n@ consecutive cycles.

Used for the button and the switch, which are plain mechanical contacts and will
bounce for a few milliseconds. Not used for the quadrature channels: a long
filter there would swallow genuinely fast rotation, and bounce on A or B is
already harmless, since it produces @+1@/@-1@ pairs that cancel out.
-}
debounce ::
  forall n dom.
  (HiddenClockResetEnable dom, KnownNat n, 1 <= n) =>
  SNat n ->
  Signal dom Bool ->
  Signal dom Bool
debounce SNat inp = out
 where
  -- The pin is asynchronous to this clock, so synchronise before comparing.
  synced = register False (register False inp)

  out = register False out'
  cnt = register (0 :: Index n) cnt'
  (out', cnt') = unbundle (step <$> synced <*> out <*> cnt)

  step i o c
    | i == o = (o, 0)
    | c == maxBound = (i, 0)
    | otherwise = (o, c + 1)
{-# OPAQUE debounce #-}

quadratureEncoder ::
  forall dom precision .
  ( HiddenClockResetEnable dom
  , KnownNat precision
   ) =>
  Signal dom (BitVector 2) -> Signal dom (Index precision)
quadratureEncoder = mealy go (0, 0 :: Index precision)
 where
  go (old, pos) ab = ((ab, nextPos), pos)
   where
    delta = quadratureDelta old ab
    nextPos
      | pos == maxBound && delta > 0 = 0
      | pos == minBound && delta < 0 = maxBound
      | otherwise = bitCoerce $ truncateB @_ @_ @1 $ numConvert pos + resize delta

{-# OPAQUE quadratureEncoder #-}

{- | A Wishbone device for a Digilent Pmod ENC: a rotary encoder with a push
button and a slide switch.

It exposes three read-only registers -- @position@, @button@ and @switch@ -- so
software can just read the current state; there is nothing to write and no
interrupt to service.

@position@ counts __quadrature edges__: it moves by one for every state change on
A/B, so a knob with four states per detent advances it four times per click.
Software divides down to whatever unit it wants to show.
-}
rotaryEncoder ::
  forall dom aw width debounceCycles hardPrecision .
  ( HasCallStack
  , HiddenClockResetEnable dom
  , KnownNat aw
  , KnownNat width
  , 1 <= width
  , KnownNat debounceCycles
  , 1 <= debounceCycles
  , 1 <= hardPrecision
  , ?byteOrder :: ByteOrder
  ) =>
  {- | How long the button and switch have to read steady before the change is
  believed. Like 'Workshop.Top.resetController''s hold time this is a parameter
  rather than a constant so that tests can pick a length a simulation can
  actually run through; the SoC passes 'DebounceCycles'.
  -}
  SNat debounceCycles ->
  SNat hardPrecision ->
  -- | The Pmod's four lines.
  Signal dom EncoderPins ->
  Circuit (ToConstBwd Mm, Wishbone dom 'Standard aw width) ()
rotaryEncoder debounceCycles SNat (dflipflop -> pins0) = circuit $ \wb -> do
  [positionSlot, buttonSlot, switchSlot] <-
    deviceWbI (deviceConfig "RotaryEncoder") -< wb

  let
    enc0 = fmap pack $ bundle (pins0.encA, pins0.encB)
    position = quadratureEncoder enc0 :: Signal dom (Index hardPrecision)

  registerWbI_ positionCfg 0 -< (positionSlot, Fwd (Just <$> position))
  registerWbI_ buttonCfg False -< (buttonSlot, Fwd (Just <$> button))
  registerWbI_ switchCfg False -< (switchSlot, Fwd (Just <$> switch))
 where

  readOnly cfg = cfg{Reg.access = ReadOnly}
  positionCfg =
    readOnly $ registerConfig "position" "Quadrature edges turned since reset; up is clockwise"
  buttonCfg = readOnly $ registerConfig "button" "Whether the shaft button is pressed"
  switchCfg = readOnly $ registerConfig "switch" "Whether the slide switch is on"
  button = debounce debounceCycles (bitToBool <$> pins0.encBtn)
  switch = debounce debounceCycles (bitToBool <$> pins0.encSwt)

{- | Contact-bounce filter length for the button and switch: at 48 MHz this is
about 1 ms, comfortably longer than the few hundred microseconds a small tactile
switch rings for, and far too short to notice by hand.
-}
type DebounceCycles = 48_000
