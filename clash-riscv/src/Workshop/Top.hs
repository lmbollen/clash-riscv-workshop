{-# OPTIONS_GHC -fplugin=Protocols.Plugin #-}
-- 'createDomain' below generates a warning about orphan instances, but we like
-- our code to be warning-free.
{-# OPTIONS_GHC -Wno-orphans #-}

{- | The synthesizable top of the workshop SoC.

"Workshop.Soc" hands the CPU's serial port to the outside world as a stream of
bytes, which is convenient in Haskell but is not something an FPGA pin can carry.
This module puts a real UART behind it: the byte stream is serialised onto a
single transmit wire, and a single receive wire is deserialised back into bytes.
Alongside it the CPU's JTAG debug port is brought out, so a debugger can halt the
core, load firmware into the instruction memory and single-step it.

Modelled on @Bittide.Instances.Pnr.ProcessingElement@ from the bittide-hardware
project.
-}
module Workshop.Top where

import Clash.Prelude

import Clash.Annotations.TH (makeTopEntity)
import Clash.Class.BitPackC (ByteOrder (LittleEndian))
import Clash.Cores.Uart (ValidBaud)
import Protocols
import VexRiscv (DumpVcd (NoDumpVcd), Jtag, JtagIn, JtagOut)

import qualified Protocols.Df as Df
import qualified Protocols.MemoryMap as Mm

import Workshop.Cpu (PeConfig (..), processingElement)
import Workshop.Peripheral (serialBytes, uartDf, unsafeToDf)

{- | The board clock this design is written for. Derived from 'vXilinxSystem'
rather than 'vSystem' so that resets are synchronous, which is what the FPGA
fabric wants; this matches @Bittide.Instances.Domains.Basic50@.
-}
createDomain vXilinxSystem{vName = "Basic50", vPeriod = hzToPeriod 50e6}

{- | Line rate of the UART. 'ValidBaud' only requires the clock to run at least
16 times as fast as this, which 50 MHz comfortably does.
-}
type Baud = 115_200

baud :: SNat Baud
baud = SNat

{- | The SoC of "Workshop.Soc" with its byte streams terminated in a UART, so
that everything crossing the boundary is a single wire.

Note that this changes nothing about the memory map: the CPU still talks to the
same @SerialBytes@ device at the same address, and the UART sits entirely
outside the bus.
-}
socUart ::
  forall dom baudRate.
  ( HiddenClockResetEnable dom
  , ValidBaud dom baudRate
  , ?byteOrder :: ByteOrder
  ) =>
  SNat baudRate ->
  PeConfig 3 ->
  Circuit
    (ToConstBwd Mm.Mm, (Jtag dom, CSignal dom Bit))
    (CSignal dom Bit)
socUart baudRate peConfig = circuit $ \(mm, (jtag, uartRx)) -> do
  [serialBus] <- processingElement NoDumpVcd peConfig -< (mm, jtag)
  serialOut <- serialBytes -< (serialIn, serialBus)
  (rxByte, uartTx) <- uartDf baudRate -< (serialOut, uartRx)
  -- A received byte is on the wire for one cycle only, while the CPU may take
  -- thousands to come around to reading it, so give it somewhere to wait.
  serialIn <- Df.fifo d16 <| unsafeToDf -< rxByte
  idC -< uartTx

{- | Clock, reset, the four JTAG pins and the two serial pins.

The instruction and data memories start out empty, so out of reset the CPU has
nothing to run: firmware arrives over JTAG. To bake it into the bitstream
instead, hand 'initI' / 'initD' the images that @bin/Sim.hs@ builds with
'Workshop.Firmware.loadElfMemories'.
-}
topEntity ::
  "CLK" ::: Clock Basic50 ->
  "RST" ::: Reset Basic50 ->
  "JTAG" ::: Signal Basic50 JtagIn ->
  "UART_RX" ::: Signal Basic50 Bit ->
  ""
    ::: ( "JTAG" ::: Signal Basic50 JtagOut
        , "UART_TX" ::: Signal Basic50 Bit
        )
topEntity clk rst jtagIn uartRx = (jtagOut, uartTx)
 where
  ((jtagOut, ()), uartTx) =
    let ?byteOrder = LittleEndian
     in toSignals
          (withClockResetEnable clk rst enableGen (Mm.unMemmap (socUart baud peConfig)))
          ((jtagIn, uartRx), ())

  peConfig :: PeConfig 3
  peConfig =
    PeConfig
      { depthI = SNat @1024
      , depthD = SNat @1024
      , initI = Nothing
      , initD = Nothing
      }
{-# OPAQUE topEntity #-}
makeTopEntity 'topEntity
