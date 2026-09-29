{-# LANGUAGE ImplicitParams #-}

{- | The SoC's serial port: a one-byte Wishbone device, and the UART that puts it
on a wire.

Two halves that are deliberately separate. 'serialBytes' is the /peripheral/ -- a
single register the CPU reads and writes, which appears in the memory map and is
what the generated PAC and the Rust driver see. 'uartDf' is the /pin interface/ --
it serialises those bytes onto a transmit line and deserialises a receive line
back. Nothing about the memory map changes when the UART is added or removed,
because the UART sits entirely outside the bus.

"Workshop.Soc" instantiates the first and "Workshop.Top" adds the second.
-}
module Workshop.Peripheral.Serial (
  serialBytes,
  uartDf,
  unsafeFromDf,
  unsafeToDf,
) where

import Clash.Prelude

import Clash.Class.BitPackC (ByteOrder (..))
import Clash.Cores.Uart (ValidBaud, uart)

import Data.Maybe
import GHC.Stack (HasCallStack)

import Protocols
import Protocols.Experimental.Wishbone
import Protocols.MemoryMap
import Protocols.MemoryMap.Registers.WishboneStandard

import qualified Protocols.Df as Df

serialBytes ::
  ( HasCallStack
  , HiddenClock dom
  , HiddenReset dom
  , KnownNat aw
  , KnownNat width
  , 1 <= width
  , ?byteOrder :: ByteOrder
  ) =>
  Circuit
    (Df dom (BitVector 8), (ToConstBwd Mm, Wishbone dom 'Standard aw width))
    (Df dom (BitVector 8))
serialBytes = circuit $ \(byteIn0, wb) -> do
  [wb0] <- deviceWbI deviceCfg -< wb
  Fwd byteIn1 <- unsafeFromDf -< (byteIn0, Fwd busReadAck)
  (_reg, busActivity) <- registerWbDfI registerCfg 0 -< (wb0, Fwd byteIn1)
  let readAvailable = fmap (Ack . isJust) byteIn1
  Fwd busReadData <- unsafeFromDf -< (busRead, Fwd readAvailable)
  let busReadAck = fmap (Ack . isJust) busReadData
  -- 'Df.partition' routes elements matching the predicate to the *first* output.
  (busWrite, busRead) <- Df.partition isBusWrite -< busActivity
  applyC (fmap busActivityWrite) id -< busWrite
 where
  deviceCfg = deviceConfig devName
  registerCfg = registerConfig regName regDescription
  devName = "SerialBytes"
  regName = "byte"
  regDescription = "Receives or sends a single byte"

  isBusWrite (BusWrite _) = True
  isBusWrite _ = False


{- | Deconstructs a `Df` into its channels represented as `CSignal`s.
This function is unsafe, because it allows losing or duplicating data if
the receiving circuit does not respect the `Df` protocol.
-}
unsafeFromDf :: Circuit (Df dom a, CSignal dom Ack) (CSignal dom (Maybe a))
unsafeFromDf = Circuit $ \((dfFwd, dfBwd), _) -> ((dfBwd, ()), dfFwd)

{- | Constructs a `Df` from a `CSignal` of `Maybe`s.
This function is unsafe, because the producing circuit gets no backpressure: a
value offered while the receiver is not ready is silently dropped.
-}
unsafeToDf :: Circuit (CSignal dom (Maybe a)) (Df dom a)
unsafeToDf = Circuit $ \(maybes, _ack) -> ((), maybes)

{- | The UART core from @clash-cores@ dressed up as a 'Circuit': it serialises
bytes from the 'Df' input onto the transmit line, and deserialises the receive
line back into bytes.

The received bytes come out as a plain 'CSignal' rather than a 'Df', because the
line has no way to be told to wait: a byte is presented for a single cycle and
then it is gone. Buffer it (see 'Workshop.Top.socUart') if the consumer cannot
keep up.

This is @Bittide.Wishbone.uartDf@ from the bittide-hardware project.
-}
uartDf ::
  (HiddenClockResetEnable dom, ValidBaud dom baud) =>
  SNat baud ->
  {- | Left side of circuit: byte to send, receive line
  Right side of circuit: received byte, transmit line
  -}
  Circuit
    (Df dom (BitVector 8), CSignal dom Bit)
    (CSignal dom (Maybe (BitVector 8)), CSignal dom Bit)
uartDf baud = Circuit go
 where
  go ((request, rxBit), _) = ((Ack <$> ack, ()), (received, txBit))
   where
    (received, txBit, ack) = uart baud rxBit request
