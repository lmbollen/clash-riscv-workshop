-- | Simulation test: load the hello-world firmware into the SoC, run it, and
-- check that the CPU writes "Hello world" out the SerialBytes peripheral.
module Main where

import Clash.Prelude

import Clash.Class.BitPackC (ByteOrder (LittleEndian))
import Data.Char (chr)
import Data.Maybe (catMaybes)
import Protocols
import Protocols.Experimental.Simulate (SimulationConfig (..), sampleC)
import Protocols.Idle (idleSink, idleSource)
import System.FilePath ((</>))
import VexRiscv (DumpVcd (NoDumpVcd))

import qualified Protocols.MemoryMap as Mm

import Workshop.Cpu (PeConfig (..))
import Workshop.Firmware (loadElfMemories)
import Workshop.Peripheral.Encoder (idleEncoderPins)
import Workshop.Soc (socC)
import Workshop.Utils (findParentContaining)

-- | The device under test: the SoC, with no external serial input, exposing the
-- SerialBytes output stream. (Same wiring as 'Workshop.Soc.soc', but with the
-- firmware loaded into the CPU's memories.)
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
            socC NoDumpVcd peConfig (pure idleEncoderPins) -< (mm, (jtag, serialIn, udpIn))
          idleSink -< udpOut
          idC -< serialOut

main :: IO ()
main = do
  root <- findParentContaining "cabal.project"
  let elfPath =
        root
          </> "_build"
          </> "cargo"
          </> "riscv32imc-unknown-none-elf"
          </> "release"
          </> "hello-world"

  (iMem, dMem) <- loadElfMemories @2048 @2048 elfPath

  let peConfig :: PeConfig 5
      peConfig = PeConfig (SNat @2048) (SNat @2048) (Just iMem) (Just dMem)
      simConfig = def{timeoutAfter = 1_000_000}
      output = catMaybes (sampleC simConfig (Mm.unMemmap (dut peConfig)))
      captured = fmap toChar output

  putStr captured
 where
  toChar :: BitVector 8 -> Char
  toChar b = chr (fromIntegral (unpack b :: Unsigned 8))
