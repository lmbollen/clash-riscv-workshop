{- | Simulation test for the /baked-in/ firmware.

@bin\/Sim.hs@ loads the ELF at runtime and feeds it to the SoC as a word-wide
'DoubleBufferedRam.Vec' image. The FPGA build cannot do that: it needs the image
present at compile time, pre-split into byte lanes
('Workshop.Firmware.loadElfMemoriesTH' / 'DoubleBufferedRam.ByteLanes'). That is
a genuinely different path through the memory initialisation -- a lane ordering
mistake there would leave the CPU executing garbage on hardware while the
runtime-loaded simulation kept passing happily.

So this runs the exact image the bitstream contains, and checks it still greets
us. Run with @cabal run sim-baked@.
-}
module Main where

import Clash.Prelude

import Clash.Class.BitPackC (ByteOrder (LittleEndian))
import Data.Char (chr)
import Data.Maybe (catMaybes)
import Protocols
import Protocols.Experimental.Simulate (SimulationConfig (..), sampleC)
import Protocols.Idle (idleSink, idleSource)
import System.Exit (exitFailure, exitSuccess)
import VexRiscv (DumpVcd (NoDumpVcd))

import qualified Data.List as L
import qualified Protocols.MemoryMap as Mm

import Workshop.Cpu (PeConfig (..))
import Workshop.Peripheral.Encoder (EncoderPins (..))
import Workshop.Soc (socC)
import Workshop.Top (firmware)

{- | A rotary encoder being turned steadily clockwise.

Walks the quadrature pair through its Gray sequence @00 -> 01 -> 11 -> 10@,
holding each state long enough that the peripheral's two-flop synchroniser sees
it, and slowly enough that the CPU gets to run between detents. Four states makes
one detent, so @position@ should climb.

The button and switch stay put: their debounce window is 48000 cycles, which
would dominate the run.
-}
turningClockwise :: forall dom. (HiddenClockResetEnable dom) => Signal dom EncoderPins
turningClockwise = pins
 where
  counter :: Signal dom (Unsigned 32)
  counter = register 0 (counter + 1)

  -- One quadrature state every 2048 cycles.
  quarter = (\c -> truncateB (c `shiftR` 11) :: Unsigned 2) <$> counter

  pins = toPins <$> quarter
  toPins q =
    let (a, b) = grayCode q
     in EncoderPins{encA = a, encB = b, encBtn = low, encSwt = low}

  grayCode :: Unsigned 2 -> (Bit, Bit)
  grayCode 0 = (low, low)
  grayCode 1 = (low, high)
  grayCode 2 = (high, high)
  grayCode _ = (high, low)

-- | Same wiring as 'Workshop.Soc.soc', with no serial input.
dut ::
  PeConfig 5 ->
  Circuit (ToConstBwd Mm.Mm, ()) (Df System (BitVector 8))
dut peConfig =
  let ?byteOrder = LittleEndian
   in withClockResetEnable clockGen (resetGenN d2) enableGen
        $ circuit
        $ \(mm, _noInput) -> do
          jtag <- idleSource -< ()
          serialIn <- idleSource -< ()
          -- No Ethernet in simulation: the stack that would drive it lives in
          -- Workshop.Top, alongside the pins.
          udpIn <- idleSource -< ()
          (serialOut, udpOut, _ethCfg) <-
            socC NoDumpVcd peConfig turningClockwise -< (mm, (jtag, serialIn, udpIn))
          idleSink -< udpOut
          idC -< serialOut

main :: IO ()
main = do
  case firmware of
    Nothing -> do
      putStrLn "FAIL: no firmware baked in; build it and recompile."
      exitFailure
    Just (iMem, dMem) -> do
      let peConfig :: PeConfig 5
          peConfig = PeConfig (SNat @2048) (SNat @2048) (Just iMem) (Just dMem)
          simConfig = def{timeoutAfter = 1_000_000}
          captured =
            fmap toChar
              $ catMaybes
              $ sampleC simConfig (Mm.unMemmap (dut peConfig))
      putStrLn "captured:"
      putStrLn captured
      -- Two separate things are being checked: that the image the bitstream
      -- carries boots at all, and that the CPU can see the rotary encoder the
      -- stimulus above is turning.
      let greeted = "Hello world" `L.isInfixOf` captured
          sawEncoder = "turned cw" `L.isInfixOf` captured
      if greeted && sawEncoder
        then do
          putStrLn "PASS: the baked-in image boots, prints, and reads the encoder."
          exitSuccess
        else do
          if greeted
            then putStrLn "FAIL: the CPU never reported the encoder turning."
            else putStrLn "FAIL: no greeting."
          exitFailure
 where
  toChar :: BitVector 8 -> Char
  toChar b = chr (fromIntegral (unpack b :: Unsigned 8))
