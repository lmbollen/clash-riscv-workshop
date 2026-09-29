{- | The receive half of an RMII interface, for the LAN8720A on
<https://github.com/swetland/ethernet-pmod swetland's Ethernet Pmod>.

RMII carries a 100 Mbit/s link over a 50 MHz clock by moving two bits at a time.
The Pmod's PHY is strapped @nINTSEL=1@, so the FPGA supplies that 50 MHz (see
"Workshop.Clocks") and everything below is synchronous to it -- including, and
this is the part worth remembering, the PHY's /outputs/. There is no separate
receive clock to recover: the same edge that leaves the FPGA comes back having
been through the PHY.

The Pmod's MDIO and MDC are on a second header, not on the Pmod connector, so
there is no management access here at all. That is fine, and deliberate on the
board's part: it is strapped @MODE=111@, which is \"auto-negotiate everything\",
so the link comes up on its own with no register writes.
-}
module Workshop.Peripheral.Ethernet.Rmii where

import Clash.Prelude

import Clash.Cores.Crc (deriveHardwareCrc)
import Clash.Cores.Crc.Catalog (Crc32_ethernet (..))
import Protocols
import Protocols.PacketStream

{- | The Ethernet frame check sequence, computed and checked a byte at a time.

Derived here, once, because it is an instance: deriving it in two modules would
be two instances of the same class for the same types. Both the MAC stack in
"Workshop.Top" uses this one.
-}
$(deriveHardwareCrc Crc32_ethernet d8 d1)

{- | What the PHY drives at us. The field names carry their own port names, so a
top-level @"ETH" ::: Signal dom RmiiIn@ port flattens to @ETH_CRS_DV@,
@ETH_RXD0@ and @ETH_RXD1@ -- the same trick 'Workshop.Peripheral.Encoder.EncoderPins'
uses.
-}
data RmiiIn = RmiiIn
  { rmiiRxd0 :: "RXD0" ::: Bit
  -- ^ Receive data, low bit of the di-bit.
  , rmiiRxd1 :: "RXD1" ::: Bit
  -- ^ Receive data, high bit of the di-bit.
  }
  deriving (Generic, NFDataX, BitPack, ShowX, Eq)

-- | Nothing arriving: both data lines idle.
idleRmiiIn :: RmiiIn
idleRmiiIn = RmiiIn{rmiiRxd0 = low, rmiiRxd1 = low}

{- | What we drive at the PHY, apart from the reference clock (which is a
'Clock', not a 'Signal', and so is a port of its own).

Transmit is wired up but held quiet: this design only listens. The lines still
have to be driven rather than left floating, because a floating @TXEN@ is a PHY
that transmits noise.
-}
data RmiiOut = RmiiOut
  { rmiiRstN :: "RSTN" ::: Bit
  -- ^ PHY reset, active __low__.
  , rmiiTxEn :: "TXEN" ::: Bit
  -- ^ Transmit enable. Held low.
  , rmiiTxd0 :: "TXD0" ::: Bit
  -- ^ Transmit data, low bit. Held low.
  , rmiiTxd1 :: "TXD1" ::: Bit
  -- ^ Transmit data, high bit. Held low.
  }
  deriving (Generic, NFDataX, BitPack, ShowX, Eq)

-- | The two receive data lines as the di-bit they are: @RXD1@ high, @RXD0@ low.
rmiiDibit :: RmiiIn -> BitVector 2
rmiiDibit pins = pack (pins.rmiiRxd1, pins.rmiiRxd0)

{- | How long the PHY is held in reset: 1 ms at 50 MHz.

The LAN8720A datasheet asks for at least 100 us with the reference clock already
running. This design cannot start it any earlier than that anyway -- the counter
is clocked by the very clock the PHY is waiting for -- and a full millisecond
costs nothing on a link that then spends a second or two coming up.
-}
type PhyResetCycles = 50_000

{- | How long the MODE strap is held after reset is released: 64 cycles, 1.3 us
at 50 MHz.

The strap is latched by the PHY /at/ the rising edge of @RSTn@, so it has to be
valid across that edge rather than merely before it. Holding it a little longer
covers the latch and costs nothing, because a LAN8720A coming out of reset takes
far longer than a microsecond to start driving anything -- so the override is
long gone before the pin turns around and becomes an output.
-}
type StrapHoldCycles = 64

{- | Bring the PHY up: release its reset, and hold the @MODE@ strap override
across the moment that reset is latched.

Returns @(RSTn, drive the strap)@. @RSTn@ is active low, so it is the signal to
wire straight to 'rmiiRstN'; the second is an output enable for whatever is
overriding a strap pin -- see 'ForcedMode'.
-}
phyBringUp ::
  forall cycles dom.
  ( HiddenClockResetEnable dom
  , KnownNat cycles
  , 1 <= cycles
  ) =>
  SNat cycles ->
  (Signal dom Bit, Signal dom Bool)
phyBringUp SNat = (rstN, strapDrive)
 where
  counter :: Signal dom (Index (cycles + StrapHoldCycles))
  counter = register 0 (satSucc SatBound <$> counter)

  rstN = boolToBit . (>= natToNum @cycles) <$> counter
  strapDrive = (< maxBound) <$> counter

{- | Hold the PHY in reset for 'PhyResetCycles', then release it. Kept for
designs that do not override a strap; 'phyBringUp' is the one to use when they
do.
-}
phyResetN ::
  forall cycles dom.
  (HiddenClockResetEnable dom, KnownNat cycles, 1 <= cycles) =>
  SNat cycles ->
  Signal dom Bit
phyResetN SNat = boolToBit . (== maxBound) <$> counter
 where
  counter :: Signal dom (Index cycles)
  counter = register 0 (satSucc SatBound <$> counter)

{- Why a design would drive one of the PHY's own strap pins.

@MODE[2:0]@ on the LAN8720A is latched from @RXD0@, @RXD1@ and @CRS_DV@ at reset,
and the Pmod fits 10k pull-ups on all three, which selects @MODE=111@:
auto-negotiate, advertise everything. That is the right default for a board that
does not know what it will be plugged into, and it is a bad default here, because
it makes the link conditional on a negotiation completing -- and until the link
is up the PHY has no reason to drive its RMII outputs at all, so a design waiting
to see @CRS_DV@ move is waiting on the very thing that is not happening.

@MODE=011@ is 100BASE-TX full duplex with auto-negotiation __off__: the PHY
simply transmits and receives at 100 Mbit/s. That needs @CRS_DV@ (which is
@MODE2@) low when the strap is latched, and the other two left high, so exactly
one pin has to be overridden -- and only for the microsecond around reset, after
which it is released and goes back to being the receive-valid input.

The far end does not have to be told. A partner with auto-negotiation on sees
100BASE-TX idles and links by parallel detection, at 100 Mbit/s half duplex.
-}

{- | A byte split into the four di-bits RMII sends it as, first one first.

Ethernet goes out least-significant bit first, so the first di-bit on the wire is
bits 1..0 and the last is bits 7..6. 'unpack' hands back the most significant
pair first, so this reverses it. Both directions below share this, which is what
makes them agree.
-}
rmiiDibits :: BitVector 8 -> Vec 4 (BitVector 2)
rmiiDibits = reverse . unpack

-- | Where the receive adapter is within a frame.
data RmiiRxState
  = -- | No carrier.
    RmiiRxIdle
  | -- | Carrier, but the preamble has not started yet.
    RmiiRxAlign
  | -- | Assembling: di-bit position, accumulator, and the previous complete byte
    -- waiting to be handed on.
    RmiiRxByte (Index 4) (BitVector 8) (Maybe (BitVector 8))
  deriving (Generic, NFDataX, ShowX, Eq)

{- | RMII receive pins to a 'PacketStream' of bytes.

This is the PHY adapter that @Clash.Cores.Ethernet@'s receive stack plugs into,
and its job stops early: it hands on the frame __exactly as it arrives__,
preamble and frame check sequence included. Stripping the preamble, validating
the FCS, widening the stream and matching the destination address are all
'Clash.Cores.Ethernet.Examples.RxStacks.macRxStack''s business, and doing any of
it here would mean doing it twice or wrongly.

Two things it does have to get right, because nothing downstream can recover
them:

  * __Byte alignment.__ RMII delivers two bits per cycle with no framing of its
    own, so where a byte begins is decided here and nowhere else. Carrier can
    rise a little before the preamble does, with @RXD@ still at @00@; the first
    non-zero di-bit is the start of the preamble's first byte, and everything is
    counted in fours from there. Get this wrong by one di-bit and the SFD check
    downstream simply never matches.
  * __The end of the packet.__ @_last@ has to be set on the final transfer, but
    a byte is only known to be final once carrier has already dropped. So one
    byte is held back: each completed byte is handed on when the /next/ one
    completes, and the one still held when carrier falls is the one marked last.
    A partial byte at that point is a fragment and is dropped -- its FCS could
    not have been valid anyway.

__Unsafe__: RMII cannot be told to wait, so backpressure is ignored. At one byte
every four cycles into a stack that accepts one per cycle this has enormous
headroom, but a stalled consumer loses bytes rather than stalling the wire.
-}
unsafeRmiiRxC ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  -- | Carrier sense / data valid. Separate from the data pins because it doubles
  -- as the @MODE2@ strap and so lives on a bidirectional port.
  Signal dom Bool ->
  -- | The two receive data pins, already synchronised to @dom@.
  Signal dom RmiiIn ->
  Circuit () (PacketStream dom 1 ())
unsafeRmiiRxC crsDv pins = Circuit $ \_ -> ((), fwd)
 where
  fwd = mealy step RmiiRxIdle (bundle (crsDv, rmiiDibit <$> pins))

  step :: RmiiRxState -> (Bool, BitVector 2) -> (RmiiRxState, Maybe (PacketStreamM2S 1 ()))
  step st (crsDv, d) = case st of
    _ | not crsDv -> (RmiiRxIdle, endOfPacket)
    RmiiRxIdle -> (RmiiRxAlign, Nothing)
    RmiiRxAlign
      | d /= 0 -> (RmiiRxByte 1 (shiftIn 0 d) Nothing, Nothing)
      | otherwise -> (RmiiRxAlign, Nothing)
    RmiiRxByte i acc held
      | i == maxBound -> (RmiiRxByte 0 0 (Just acc'), transfer Nothing <$> held)
      | otherwise -> (RmiiRxByte (i + 1) acc' held, Nothing)
     where
      acc' = shiftIn acc d
   where
    endOfPacket = case st of
      RmiiRxByte _ _ held -> transfer (Just 1) <$> held
      _ -> Nothing

  -- Di-bits arrive least significant first, so each one drops in at the top and
  -- pushes the earlier ones down; after four the byte reads the right way round.
  shiftIn :: BitVector 8 -> BitVector 2 -> BitVector 8
  shiftIn acc d = (acc `shiftR` 2) .|. (resize d `shiftL` 6)

  transfer :: Maybe (Index 2) -> BitVector 8 -> PacketStreamM2S 1 ()
  transfer lst b = PacketStreamM2S{_data = b :> Nil, _last = lst, _meta = (), _abort = False}

-- | Where the transmit adapter is: the byte going out, and how far into it.
type RmiiTxState = Maybe (BitVector 8, Index 4)

{- | A 'PacketStream' of bytes to RMII transmit pins.

The counterpart of 'unsafeRmiiRxC', and just as narrow: everything that makes
the bytes a valid frame -- preamble, padding to the 60-byte minimum, the frame
check sequence, and the interpacket gap --  has already been inserted by
'Clash.Cores.Ethernet.Examples.TxStacks.macTxStack' by the time they arrive
here. This only serialises them, two bits per cycle, and raises @TXEN@ while it
does.

Backpressure /is/ honoured in this direction: the stream is told to wait for
three cycles out of every four, which is what holds the whole stack down to the
wire's rate rather than the fabric's.
-}
unsafeRmiiTxC ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  -- | @(TXEN, TXD)@.
  Circuit (PacketStream dom 1 ()) (CSignal dom (Bit, BitVector 2))
unsafeRmiiTxC = Circuit go
 where
  go (fwdIn, _) = (bwdOut, out)
   where
    (bwdOut, out) = mealyB step Nothing fwdIn

  step :: RmiiTxState -> Maybe (PacketStreamM2S 1 ()) -> (RmiiTxState, (PacketStreamS2M, (Bit, BitVector 2)))
  step st inp = (next, (PacketStreamS2M ready, out))
   where
    -- Ready depends on the state alone, never on the input: the byte being
    -- shifted out is finished on the fourth cycle whatever upstream is offering.
    ready = case st of
      Nothing -> True
      Just (_, d) -> d == maxBound

    out = case st of
      Just (b, d) -> (high, rmiiDibits b !! d)
      Nothing -> (low, 0)

    next = case st of
      Just (b, d) | d /= maxBound -> Just (b, d + 1)
      _ -> (\m -> (head m._data, 0)) <$> inp
