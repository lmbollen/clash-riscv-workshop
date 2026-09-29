{-# OPTIONS_GHC -fplugin=Protocols.Plugin #-}

{- | An example System-on-Chip: a VexRiscv processing element (CPU +
instruction/data memory) with three external Wishbone peripherals -- the
'serialBytes' device, a 'rotaryEncoder' and an 'ethernetWb' UDP socket. It exists
to show how the building blocks are wired into a complete SoC and how its memory
map is extracted.

The Ethernet device is only the buffers and registers; the stack that fills them
lives in "Workshop.Top", which owns the pins and the PHY's clock. So this module
passes the application-level packet stream straight through, and hands back the
addressing the stack needs -- which software, not the bitstream, decides.
-}
module Workshop.Soc (socC, soc, memoryMap) where

import Clash.Prelude

import Protocols
import Protocols.Idle (idleSink, idleSource)
import Protocols.MemoryMap (Mm, MemoryMap, getMMAny)
import Protocols.PacketStream (PacketStream, downConverterC, upConverterC)

import Clash.Class.BitPackC (ByteOrder (LittleEndian))
import Clash.Cores.Ethernet.IP.IPv4Types (IPv4Address, IPv4SubnetMask)
import Clash.Cores.Ethernet.Mac (MacAddress)
import Clash.Cores.Ethernet.Udp (UdpHeaderLite)
import VexRiscv (DumpVcd (NoDumpVcd), Jtag)

import Workshop.Cpu (PeConfig (..), processingElement)
import Workshop.Peripheral.Encoder (
  DebounceCycles,
  EncoderPins,
  Positions,
  idleEncoderPins,
  rotaryEncoder,
 )
import Workshop.Peripheral.Ethernet (ethernetWb)
import Workshop.Peripheral.Serial (serialBytes)

-- | What the CPU tells the Ethernet stack about itself: our MAC, our IPv4
-- address and subnet mask, and the UDP port we listen on.
type EthAddressing = (MacAddress, (IPv4Address, IPv4SubnetMask), Unsigned 16)

-- | Application-level packets: a UDP payload, and who it is from or going to.
type UdpStream dom = PacketStream dom 1 (IPv4Address, UdpHeaderLite)

{- | The SoC proper: domain-polymorphic, with the clock, reset and pins supplied
by the caller.

Everything that ends up in the memory map lives here, and both users of the
design go through it — 'soc', which is what @Workshop.MemoryMaps@ reads the map
out of, and "Workshop.Top", which is what reaches the FPGA. That matters: the
addresses the generated Rust uses come from the map, while the hardware comes
from the top entity, so if the two ever instantiated peripherals in different
orders the firmware would quietly talk to the wrong device. Sharing one body
makes that impossible rather than merely unlikely.
-}
socC ::
  forall dom.
  ( HiddenClockResetEnable dom
  , ?byteOrder :: ByteOrder
  ) =>
  DumpVcd ->
  PeConfig 5 ->
  -- | The rotary encoder's four lines.
  Signal dom EncoderPins ->
  Circuit
    (ToConstBwd Mm, (Jtag dom, Df dom (BitVector 8), UdpStream dom))
    (Df dom (BitVector 8), UdpStream dom, CSignal dom EthAddressing)
socC dumpVcd peConfig encPins = circuit $ \(mm, (jtag, serialIn, udpIn1)) -> do
  -- 5 busses: 2 internal (instruction + data memory) + 3 external.
  [serialBus, encoderBus, ethBus] <- processingElement dumpVcd peConfig -< (mm, jtag)
  serialOut <- serialBytes -< (serialIn, serialBus)
  rotaryEncoder (SNat @DebounceCycles) (SNat @Positions) encPins -< encoderBus
  (udpOut4, ethCfg) <- ethernetWb -< (ethBus, udpIn4)
  udpOut1 <- downConverterC -< udpOut4
  udpIn4 <- upConverterC -< udpIn1
  idC -< (serialOut, udpOut1, ethCfg)

{- | The SoC in the 'System' domain with nothing attached, which is the form the
memory map is extracted from.
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
          udpIn <- idleSource -< ()
          (serialOut, udpOut, _ethCfg) <-
            socC dumpVcd peConfig (pure idleEncoderPins) -< (mm, (jtag, serialIn, udpIn))
          idleSink -< udpOut
          idC -< serialOut
 where
  peConfig :: PeConfig 5
  peConfig =
    PeConfig
      { depthI = SNat @2048
      , depthD = SNat @2048
      , initI = Nothing
      , initD = Nothing
      }

-- | The memory map of 'soc', used to generate documentation / HAL code.
memoryMap :: MemoryMap
memoryMap = getMMAny (soc NoDumpVcd)
