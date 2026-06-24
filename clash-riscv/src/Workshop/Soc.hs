{-# OPTIONS_GHC -fplugin=Protocols.Plugin #-}

{- | A minimal example System-on-Chip: a VexRiscv processing element (CPU +
instruction/data memory) with a single external Wishbone peripheral, the
'serialBytes' device. This is intentionally tiny — it exists to show how the
building blocks ('processingElement', 'serialBytes') are wired into a complete
SoC and how its memory map is extracted.
-}
module Workshop.Soc (soc, memoryMap) where

import Clash.Prelude

import Protocols
import Protocols.Idle (idleSource)
import Protocols.MemoryMap (Mm, MemoryMap, getMMAny)

import Clash.Class.BitPackC (ByteOrder (LittleEndian))
import VexRiscv (DumpVcd (NoDumpVcd))

import Workshop.Cpu (PeConfig (..), processingElement)
import Workshop.Peripheral (serialBytes)

{- | The SoC. The CPU runs from internal instruction/data memory; a single
external bus is connected to the 'serialBytes' peripheral, whose byte stream is
exposed at the top level.
-}
soc ::
  DumpVcd ->
  Circuit
    (ToConstBwd Mm, Df System (BitVector 8))
    (Df System (BitVector 8))
soc dumpVcd =
  -- The memory-map registers in this design assume little-endian byte order.
  let ?byteOrder = LittleEndian
   in withClockResetEnable clockGen (resetGenN (SNat @2)) enableGen
        $ circuit
        $ \(mm, serialIn) -> do
          jtag <- idleSource -< ()
          -- 3 busses: 2 internal (instruction + data memory) + 1 external.
          [serialBus] <- processingElement dumpVcd peConfig -< (mm, jtag)
          serialOut <- serialBytes -< (serialIn, serialBus)
          idC -< serialOut
 where
  peConfig :: PeConfig 3
  peConfig =
    PeConfig
      { depthI = SNat @1024
      , depthD = SNat @1024
      , initI = Nothing
      , initD = Nothing
      }

-- | The memory map of 'soc', used to generate documentation / HAL code.
memoryMap :: MemoryMap
memoryMap = getMMAny (soc NoDumpVcd)
