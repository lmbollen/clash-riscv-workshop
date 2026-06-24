-- | Simulation test: load the hello-world firmware into the SoC, run it, and
-- check that the CPU writes "Hello world" out the SerialBytes peripheral.
module Main where

import Clash.Prelude

import Clash.Class.BitPackC (ByteOrder (LittleEndian))
import Data.Char (chr)
import Data.Maybe (catMaybes)
import Protocols
import Protocols.Experimental.Simulate (SimulationConfig (..), sampleC)
import Protocols.Idle (idleSource)
import System.FilePath ((</>))
import VexRiscv (DumpVcd (NoDumpVcd))

import qualified Protocols.MemoryMap as Mm

import Workshop.Cpu (PeConfig (..), processingElement)
import Workshop.Firmware (loadElfMemories)
import Workshop.Peripheral (serialBytes)
import Workshop.Utils (findParentContaining)

-- | The device under test: the SoC, with no external serial input, exposing the
-- SerialBytes output stream. (Same wiring as 'Workshop.Soc.soc', but with the
-- firmware loaded into the CPU's memories.)
dut ::
  PeConfig 3 ->
  Circuit (ToConstBwd Mm.Mm, ()) (Df System (BitVector 8))
dut peConfig =
  let ?byteOrder = LittleEndian
   in withClockResetEnable clockGen (resetGenN d2) enableGen
        $ circuit
        $ \(mm, _noInput) -> do
          jtag <- idleSource -< ()
          serialIn <- idleSource -< ()
          [serialBus] <- processingElement NoDumpVcd peConfig -< (mm, jtag)
          serialOut <- serialBytes -< (serialIn, serialBus)
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

  (iMem, dMem) <- loadElfMemories @1024 @1024 elfPath

  let peConfig = PeConfig (SNat @1024) (SNat @1024) (Just iMem) (Just dMem)
      simConfig = def{timeoutAfter = 1_000_000}
      output = catMaybes (sampleC simConfig (Mm.unMemmap (dut peConfig)))
      captured = fmap toChar output

  putStr captured
 where
  toChar :: BitVector 8 -> Char
  toChar b = chr (fromIntegral (unpack b :: Unsigned 8))
