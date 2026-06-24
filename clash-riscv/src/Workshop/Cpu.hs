-- SPDX-FileCopyrightText: 2022 Google LLC
--
-- SPDX-License-Identifier: Apache-2.0

{-# OPTIONS -fplugin=Protocols.Plugin #-}

module Workshop.Cpu where

import Clash.Explicit.Prelude hiding (delay)
import Clash.Prelude
import Clash.Sized.Vector.Extra (incrementWithBlacklist)

import GHC.Stack (HasCallStack)
import Protocols
import Protocols.Experimental.Wishbone
import Protocols.Idle
import VexRiscv (CpuIn (..), CpuOut (..), DumpVcd, Jtag)

import Clash.Cpus.Riscv32imc (vexRiscv)
import DoubleBufferedRam
import SharedTypes
import Wishbone

import Clash.Class.BitPackC (ByteOrder (BigEndian, LittleEndian))
import qualified VexRiscv.Reset as MinReset

import qualified Protocols.MemoryMap as Mm (
  Mm,
  withDeviceTag,
  withTag,
 )
import qualified Protocols.ToConst as ToConst
import qualified Protocols.Vec as Vec

-- | Configuration for a Processing Element.
data PeConfig nBusses where
  PeConfig ::
    forall depthI depthD nBusses.
    ( KnownNat depthI
    , 1 <= depthI
    , KnownNat depthD
    , 1 <= depthD
    , KnownNat nBusses
    , 2 <= nBusses
    , PrefixWidth nBusses <= 30
    ) =>
    { depthI :: SNat depthI
    -- ^ Depth of the instruction memory in number of 32-bit words.
    , depthD :: SNat depthD
    -- ^ Depth of the data memory in number of 32-bit words.
    , initI :: Maybe (ContentType depthI (Bytes 4))
    -- ^ Initial content of the instruction memory, can be smaller than its total depth.
    , initD :: Maybe (ContentType depthD (Bytes 4))
    }->
    PeConfig nBusses

type PrefixWidth nBusses = CLog 2 (nBusses + 1)
type RemainingBusWidth nBusses = 30 - PrefixWidth nBusses

type PeInternalBusses = 2

{- | VexRiscV based RV32IMC core together with instruction memory, data memory and
'singleMasterInterconnect'.
-}
processingElement ::
  forall dom nBusses pfxWidth.
  ( HasCallStack
  , HiddenClockResetEnable dom
  , ?byteOrder :: ByteOrder
  , KnownNat nBusses
  , PeInternalBusses <= nBusses
  , KnownNat pfxWidth
  , pfxWidth <= 30
  , pfxWidth ~ PrefixWidth nBusses
  ) =>
  DumpVcd ->
  PeConfig nBusses ->
  Circuit
    (ToConstBwd Mm.Mm, Jtag dom)
    ( Vec
        (nBusses - PeInternalBusses)
        (VexBoneMm dom (RemainingBusWidth nBusses))
    )
processingElement dumpVcd PeConfig{depthI, depthD, initI, initD} = circuit $ \(mm, jtagIn) -> do
  (iBus0, (mmDbus, dBus0)) <-
    rvCircuit dumpVcd (pure low) (pure low) (pure low) -< (mm, jtagIn)
  (pfxs, wbs) <- Vec.unzip <| singleMasterInterconnectC -< (mmDbus, dBus0)
  idleSink <| (Vec.vecCircuits $ fmap ToConst.toBwd prefixes) -< pfxs
  ([(mmI, iMemBus), dMemBus], extBusses) <- Vec.split -< wbs

  -- Instruction and data memory are never accessed explicitly by developers,
  -- only implicitly by the CPU itself. We therefore don't need to generate HAL
  -- code. We instruct the generator to skip them by adding a "no-generate" tag.
  Mm.withTag "no-generate"
    $ Mm.withDeviceTag "no-generate"
    $ wbStorage "DataMemory" depthD initD
    -< dMemBus

  iBus1 <- removeMsb -< iBus0 -- XXX: <= This should be handled by an interconnect
  Mm.withTag "no-generate"
    $ Mm.withDeviceTag "no-generate"
    $ wbStorage "InstructionMemory" depthI initI
    -< (mmI, iBus2)
  iBus2 <- arbiter -< [iMemBus, iBus1]

  idC -< extBusses
 where
  -- We use `init` to generate at least 0 prefixes with `incrementWithBlacklist`
  prefixes = iMemPfx :> (incrementWithBlacklist @(nBusses - 1) prefixBlacklist)
  -- We dont want to use address 0 or the address with only the MSB set as prefixes.
  -- Address 0 is not used because it is often used as a null pointer.
  -- The address with only the MSB set is not used because we use it for the instruction
  -- memory
  iMemPfx = rotateR 1 1
  prefixBlacklist = 0 :> iMemPfx :> Nil
  removeMsb ::
    forall aw dw.
    (KnownNat aw) =>
    Circuit
      (Wishbone dom 'Standard (aw + pfxWidth) dw)
      (Wishbone dom 'Standard aw dw)
  removeMsb = wbMap (mapAddr (truncateB :: BitVector (aw + pfxWidth) -> BitVector aw)) id

  wbMap fwd bwd = Circuit $ \(m2s, s2m) -> (fmap bwd s2m, fmap fwd m2s)

rvCircuit ::
  ( HiddenClockResetEnable dom
  , ?byteOrder :: ByteOrder
  ) =>
  DumpVcd ->
  Signal dom Bit ->
  Signal dom Bit ->
  Signal dom Bit ->
  Circuit
    (ToConstBwd Mm.Mm, Jtag dom)
    ( Wishbone dom 'Standard 30 4
    , (ToConstBwd Mm.Mm, Wishbone dom 'Standard 30 4)
    )
rvCircuit dumpVcd tInterrupt sInterrupt eInterrupt =
  case ?byteOrder of
    LittleEndian -> Circuit go
    BigEndian ->
      clashCompileError
        "Unsupported register byte order: BigEndian. The only supported mode is LittleEndian."
 where
  go (((), jtagIn), (iBusIn, (mm, dBusIn))) = ((mm, jtagOut), (iBusWbM2S <$> cpuOut, ((), dBusWbM2S <$> cpuOut)))
   where
    tupToCoreIn (timerInterrupt, softwareInterrupt, externalInterrupt, iBusWbS2M, dBusWbS2M) =
      CpuIn{timerInterrupt, softwareInterrupt, externalInterrupt, iBusWbS2M, dBusWbS2M}
    rvIn = tupToCoreIn <$> bundle (tInterrupt, sInterrupt, eInterrupt, iBusIn, dBusIn)
    (cpuOut, jtagOut) = vexRiscv dumpVcd hasClock rv32Reset rvIn jtagIn
    rv32Reset = MinReset.toMinCycles hasClock $ unsafeOrReset hasReset jtagReset
    jtagReset = unsafeFromActiveHigh (delay False (bitToBool . ndmreset <$> cpuOut))

-- | Map a function over the address field of 'WishboneM2S'
mapAddr ::
  (BitVector aw1 -> BitVector aw2) ->
  WishboneM2S aw1 selWidth ->
  WishboneM2S aw2 selWidth
mapAddr f wb = wb{addr = f (addr wb)}

