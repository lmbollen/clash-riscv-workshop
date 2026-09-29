{-# OPTIONS_GHC -fplugin=Protocols.Plugin #-}

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

import System.FilePath ((</>))

import qualified Protocols.Df as Df
import qualified Protocols.MemoryMap as Mm

import DoubleBufferedRam (ContentType)
import SharedTypes (Bytes)
import Workshop.Cpu (PeConfig (..))
import Workshop.Firmware (loadElfMemoriesTH)
import Clash.Cores.Crc (HardwareCrc)
import Clash.Cores.Crc.Catalog (Crc32_ethernet)
import Clash.Cores.Ethernet.Examples.FullUdpStack (fullStackC)
import Protocols.PacketStream (FullMode (Backpressure), packetFifoC)

import Workshop.Clocks (Dom48, Dom50, ecp5ClockOut, ecp5Pll)
import Workshop.Peripheral.Encoder (EncoderPins)
import Workshop.Peripheral.Ethernet.Rmii (
  PhyResetCycles,
  RmiiIn,
  RmiiOut (..),
  idleRmiiIn,
  phyResetN,
  unsafeRmiiRxC,
  unsafeRmiiTxC,
 )
import Workshop.Peripheral.Serial (uartDf, unsafeToDf)
import Workshop.Soc (socC)

{- | Line rate of the UART. 'ValidBaud' only requires the clock to run at least
16 times as fast as this, which 50 MHz comfortably does.
-}
type Baud = 115_200

baud :: SNat Baud
baud = SNat

{- | The compiled @hello-world@ ELF, read at compile time so that the block RAMs
come up holding it and the CPU has something to run out of reset. 'Nothing'
(with a warning) if the firmware has not been built yet -- see
'loadElfMemoriesTH'.
-}
firmware :: Maybe (ContentType 2048 (Bytes 4), ContentType 2048 (Bytes 4))
firmware =
  $( loadElfMemoriesTH
      (SNat @2048)
      (SNat @2048)
      ("_build" </> "cargo" </> "riscv32imc-unknown-none-elf" </> "release" </> "hello-world")
   )

{- | The SoC of "Workshop.Soc" with its byte streams terminated in a UART, so
that everything crossing the boundary is a single wire.

Note that this changes nothing about the memory map: the CPU still talks to the
same @SerialBytes@ device at the same address, and the UART sits entirely
outside the bus.
-}
socUart ::
  forall dom domEth baudRate.
  ( HiddenClockResetEnable dom
  , KnownDomain domEth
  , ValidBaud dom baudRate
  , HardwareCrc Crc32_ethernet 8 1
  , ?byteOrder :: ByteOrder
  ) =>
  SNat baudRate ->
  PeConfig 5 ->
  -- | The rotary encoder's four lines.
  Signal dom EncoderPins ->
  -- | The Ethernet PHY's clock domain: the 50 MHz this design hands it.
  Clock domEth ->
  Reset domEth ->
  Enable domEth ->
  -- | Carrier sense / data valid, already synchronised to @domEth@.
  Signal domEth Bool ->
  -- | The two receive data lines, already synchronised to @domEth@.
  Signal domEth RmiiIn ->
  Circuit
    (ToConstBwd Mm.Mm, (Jtag dom, CSignal dom Bit))
    (CSignal dom Bit, CSignal domEth (Bit, BitVector 2))
socUart baudRate peConfig encPins ethClk ethRst ethEn crsDv rxPins =
  circuit $ \(mm, (jtag, uartRx)) -> do
    (serialOut, udpOut, Fwd ethCfg) <-
      socC NoDumpVcd peConfig encPins -< (mm, (jtag, serialIn, udpIn))

    (rxByte, uartTx) <- uartDf baudRate -< (serialOut, uartRx)
    -- A received byte is on the wire for one cycle only, while the CPU may take
    -- thousands to come around to reading it, so give it somewhere to wait.
    serialIn <- Df.fifo d16 <| unsafeToDf -< rxByte

    {- The Ethernet stack. Its application side runs in the CPU's domain and its
    PHY side in the PHY's, and it does the crossing itself -- which is the reason
    the SoC can stay at 48 MHz while the wire runs at the 50 MHz RMII demands,
    with no clock crossing written here.

    The addressing comes back out of the SoC rather than being fixed here:
    'Workshop.Peripheral.Ethernet.ethernetWb' holds the MAC address, IP address
    and subnet mask in registers, so software decides them. -}
    phyIn <- exposeClockResetEnable (unsafeRmiiRxC crsDv rxPins) ethClk ethRst ethEn -< ()
    (udpIn, phyOut) <-
      fullStackC
        ethClk
        ethRst
        ethEn
        ethClk
        ethRst
        ethEn
        (macOf <$> ethCfg)
        (ipOf <$> ethCfg)
        -< (udpOut, phyIn)
    {- Store-and-forward, in the PHY's domain, right before the wire.

    'unsafeRmiiTxC' drops @TXEN@ the moment its input is not valid, because RMII
    has no way to pause mid-frame -- and a frame that stops early is a runt with
    no frame check sequence, which the receiver discards. So whatever feeds it
    must never stall once a frame has started.

    'fullStackC' already guarantees that for the UDP path, which it wraps in a
    packet FIFO. It does not for ICMP: that branch streams straight from the echo
    responder, and measurement showed exactly the predicted failure -- an echo
    reply with correct addresses, correct type and a correctly adjusted checksum,
    cut off 22 bytes short with @TXEN@ falling mid-frame.

    'packetFifoC' fixes it for every path at once, because it "first loads an
    entire packet before it may transmit it" and therefore emits "no gaps in
    output packets". Putting it here rather than upstream also absorbs the clock
    domains not being the same speed: the logic runs at 48 MHz and the wire at
    50 MHz, so over a long frame the consumer asks for bytes on a slightly
    different cadence than the producer supplies them. Holding the whole packet
    makes that a non-question rather than something to budget for.

    __The depth is a correctness constraint, not a performance knob.__ The FIFO
    /drops/ packets of @2^contentDepth - 1@ transfers or more. At one byte per
    transfer the largest thing that can arrive here is a maximum-length Ethernet
    frame plus its preamble: 1518 + 8 = 1526 bytes. @d11@ gives 2048 entries, so
    the limit is 2047 -- comfortably clear. @d10@ would be 1023 and would
    silently discard anything over about two thirds of an MTU, which is a
    horrible failure to debug. -}
    phyOutBuffered <-
      exposeClockResetEnable (packetFifoC d11 d4 Backpressure) ethClk ethRst ethEn
        -< phyOut
    txPins <-
      exposeClockResetEnable unsafeRmiiTxC ethClk ethRst ethEn -< phyOutBuffered

    idC -< (uartTx, txPins)
 where
  macOf (mac, _, _) = mac
  ipOf (_, ipMask, _) = ipMask

{- | How long reset is held, in cycles: about 21 ms at 48 MHz.

Long enough to swamp the contact bounce of a mechanical button (single
milliseconds), so that one press produces one reset rather than a burst of them.
-}
type ResetCycles = 1_000_000

{- | Hold the design in reset after configuration, and again for
'ResetCycles' after @btn@ is released.

@btn@ is active low, which is how a button that shorts its pin to ground
behaves. Note this cannot be a @Reset@ port: the domain is active-high (see
'Dom48'), so Clash would read a @Reset@ port as asserted-when-high and invert the
button's meaning. Taking it as a plain 'Bit' and converting here keeps the two
polarities from being conflated.

One counter covers both jobs. Registers leave ECP5 configuration holding their
initial values, so it starts at zero and reset is asserted until it saturates;
pressing the button reloads it to zero, and every bounce on release reloads it
again, so reset only lifts once the pin has been stably high for the full window.

The hold time is a parameter so that it can be tested at a length a doctest can
actually show; 'topEntity' passes 'ResetCycles'.

Held from power-on until the counter saturates, and re-asserted while the button
reads low:

>>> let held n btn = sampleN n (unsafeToActiveHigh (withClockResetEnable @System clockGen resetGen enableGen (resetController (SNat @4) btn)))
>>> held 6 (pure high)
[True,True,True,False,False,False]

A press (low for two cycles, seen two cycles later through the synchroniser)
puts it back into reset, and it stays there for the full window afterwards:

>>> held 12 (fromList ([high,high,high,high,low,low] <> L.repeat high))
[True,True,True,False,False,False,False,True,True,True,True,False]
-}
resetController ::
  forall cycles dom.
  (HiddenClock dom, HiddenEnable dom, KnownNat cycles, 1 <= cycles) =>
  -- | How long to hold reset once the button is released.
  SNat cycles ->
  -- | The board's user button, active low.
  Signal dom Bit ->
  Reset dom
resetController SNat btn = unsafeFromActiveLow ((== maxBound) <$> counter)
 where
  -- The button is asynchronous to this clock, so synchronise before using it.
  pressed = delay False (delay False ((== low) <$> btn))

  counter :: Signal dom (Index cycles)
  counter = delay 0 (step <$> pressed <*> counter)

  step True _ = 0
  step False c = satSucc SatBound c

{- | 'resetController' with no button attached: reset purely on power-on.

Used for the PHY's 50 MHz domain, which has no button to answer to -- the button
resets the CPU, and dragging the Ethernet link down with it would mean
renegotiating every time.
-}
powerOnReset :: forall dom. (HiddenClock dom, HiddenEnable dom) => Reset dom
powerOnReset = resetController (SNat @ResetCycles) (pure high)

{- | The OrangeCrab pinout: the 48 MHz oscillator, the user button, the CPU's
JTAG debug port, the two serial lines and the rotary encoder on PMOD 3. Which
balls these land on is in @data\/constraints\/orangecrab.lpf@; the names here have
to match that file.

The memories come up holding 'firmware', so the CPU starts running as soon as the
FPGA leaves configuration -- no debugger required to see it print. Pressing the
button restarts it, so the greeting can be produced again on demand.
-}
topEntity ::
  "CLK" ::: Clock Dom48 ->
  "BTN" ::: Signal Dom48 Bit ->
  "JTAG" ::: Signal Dom48 JtagIn ->
  "UART_RX" ::: Signal Dom48 Bit ->
  "ENC" ::: Signal Dom48 EncoderPins ->
  "ETH_CRS_DV" ::: Signal Dom50 Bit ->
  "ETH" ::: Signal Dom50 RmiiIn ->
  ""
    ::: ( "JTAG" ::: Signal Dom48 JtagOut
        , "UART_TX" ::: Signal Dom48 Bit
        , "ETH_CLKIN" ::: Signal Dom50 Bit
        , "ETH" ::: Signal Dom50 RmiiOut
        )
topEntity clk btn jtagIn uartRx encPins ethCrsDv ethIn =
  (jtagOut, uartTx, ecp5ClockOut clk50, ethOut)
 where
  rst = withClock clk (withEnable enableGen (resetController (SNat @ResetCycles) btn))

  {- The PHY's 50 MHz, and the domain the wire side of the Ethernet stack runs
  in. The CPU stays on the board's 48 MHz: RMII fixes the wire at 50, but the
  processing element only just closes timing at 48 and there is no reason to make
  that harder. The stack crosses between them itself. -}
  clk50 = ecp5Pll clk
  rst50 = withClock clk50 (withEnable enableGen powerOnReset)
  en50 = enableGen

  {- The PHY's outputs make a round trip out of the FPGA and back, so one
  synchronising flop before anything looks at them. -}
  ethIn0 = withClockResetEnable clk50 rst50 en50 (register idleRmiiIn ethIn)
  crsDv0 = withClockResetEnable clk50 rst50 en50 (register False (bitToBool <$> ethCrsDv))

  ((jtagOut, ()), (uartTx, txPins)) =
    let ?byteOrder = LittleEndian
     in toSignals
          ( withClockResetEnable clk rst enableGen
              $ Mm.unMemmap
                (socUart baud peConfig encPins clk50 rst50 en50 crsDv0 ethIn0)
          )
          ((jtagIn, uartRx), ((), ()))

  ethOut =
    RmiiOut
      <$> withClockResetEnable clk50 rst50 en50 (phyResetN (SNat @PhyResetCycles))
      <*> (fst <$> txPins)
      <*> (lsb . snd <$> txPins)
      <*> (msb . snd <$> txPins)

  peConfig :: PeConfig 5
  peConfig =
    PeConfig
      { depthI = SNat @2048
      , depthD = SNat @2048
      , initI = fst <$> firmware
      , initD = snd <$> firmware
      }
{-# OPAQUE topEntity #-}
makeTopEntity 'topEntity

