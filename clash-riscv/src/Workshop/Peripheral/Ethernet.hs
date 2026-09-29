{-# LANGUAGE ImplicitParams #-}
{-# OPTIONS_GHC -fplugin=Protocols.Plugin #-}

{- | A Wishbone device giving the CPU a UDP socket.

The Ethernet stack itself is @Clash.Cores.Ethernet@'s -- see "Workshop.Top",
which wires 'Clash.Cores.Ethernet.Examples.FullUdpStack.fullStackC' between the
RMII pins and this device. By the time packets reach here the preamble, frame
check sequence, Ethernet header, ARP, IP header and UDP header have all been
dealt with, and what is left is a payload and who sent it. What this module adds
is the part a stack cannot supply: somewhere to put packets, and a way for
software to get at them.

The two directions are deliberately not symmetric, because the problem is not.
__Receive is a ring__ of 'RxSlots' packet slots: software does not control when
frames arrive, and a host will happily send several back to back while the CPU is
still looking at the first. __Transmit is a single buffer__: the CPU decides when
to send, so there is nothing to queue against.

Packets are handed over whole or not at all. One that overruns a slot, or arrives
when the ring is full, is dropped by rewinding the write pointer rather than by
committing what fitted -- so software never sees a truncated packet, and never
has to distrust a length field. Anything the stack marked aborted, a frame that
failed its frame check sequence for instance, was already discarded by the packet
FIFO upstream and never reaches here.
-}
module Workshop.Peripheral.Ethernet where

import Clash.Prelude

import Clash.Class.BitPackC (ByteOrder)
import Clash.Cores.Ethernet.IP.IPv4Types (IPv4Address (..), IPv4SubnetMask (..))
import Clash.Cores.Ethernet.Mac (MacAddress (..))
import Clash.Cores.Ethernet.Udp (UdpHeaderLite (..))
import Data.Maybe (isJust)
import GHC.Stack (HasCallStack)

import Protocols
import Protocols.Experimental.ReqResp (ReqResp)
import Protocols.Experimental.Wishbone
import Protocols.MemoryMap
import Protocols.MemoryMap.Registers.WishboneStandard
import Protocols.MemoryMap.Registers.WishboneStandard.Internal (
  RegisterWb,
  RegisterWbConstraints,
 )
import Protocols.PacketStream

import qualified Protocols.MemoryMap.Registers.WishboneStandard as Reg

{- | How many received packets can be waiting at once.

Four absorbs the burst a host produces when it retries something, without
spending block RAM on a depth nothing polls fast enough to need.
-}
type RxSlots = 4

{- | Words of payload per receive slot, and the size of the transmit buffer.

128 words is 512 bytes, which is above the largest UDP payload anything here
sends and a power of two, so indexing a slot is a shift rather than a multiply.
-}
type SlotWords = 128

-- | Words in the transmit buffer.
type TxWords = 128

-- | Total words in the receive ring.
type RxWords = RxSlots * SlotWords

-- | The bus is 32 bits wide, so a word is four bytes and a byte mask is 4 bits.
type WordBytes = 4

{- | What the Ethernet stack needs to know, held in this device's registers so
that software owns it rather than the bitstream.
-}
data EthConfig dom = EthConfig
  { ethMac :: Signal dom MacAddress
  , ethIpMask :: Signal dom (IPv4Address, IPv4SubnetMask)
  , ethLocalPort :: Signal dom (Unsigned 16)
  }

-- * Memory

{- | A word-addressed memory built from four byte-wide lanes.

Four lanes rather than one 32-bit memory because the bus writes with a byte mask:
a store of one byte must leave the other three alone. Giving each lane its own
write enable is how that is done in a block RAM, and is the same split the
instruction and data memories use ("DoubleBufferedRam").

Lane @i@ holds the byte selected by bit @i@ of the mask, which is the least
significant byte first -- the order the bus numbers them in.
-}
byteLaneRam ::
  forall n dom.
  (HiddenClockResetEnable dom, KnownNat n, 1 <= n) =>
  SNat n ->
  -- | Read address; the data appears one cycle later.
  Signal dom (Index n) ->
  -- | Write: address, byte mask, data.
  Signal dom (Maybe (Index n, BitVector WordBytes, BitVector 32)) ->
  Signal dom (BitVector 32)
byteLaneRam SNat rdAddr wr = fromLanes <$> bundle lanes
 where
  lanes = imap lane (repeat @WordBytes ())

  lane i () = blockRam1 NoClearOnReset (SNat @n) 0 rdAddr (laneWrite i <$> wr)

  laneWrite i (Just (a, mask, dat))
    | testBit mask (fromEnum i) = Just (a, toLanes dat !! i)
  laneWrite _ _ = Nothing

-- | A word as four bytes, least significant first -- the order the bus's byte
-- mask numbers them in.
toLanes :: BitVector 32 -> Vec WordBytes (BitVector 8)
toLanes = reverse . unpack

-- | Inverse of 'toLanes'.
fromLanes :: Vec WordBytes (BitVector 8) -> BitVector 32
fromLanes = pack . reverse

-- * Receive ring

-- | Everything remembered about a slot once its packet is complete.
data RxMeta = RxMeta
  { rxLength :: Unsigned 16
  -- ^ Payload bytes.
  , rxSrcIp :: Vec 4 (BitVector 8)
  -- ^ Who sent it.
  , rxSrcPort :: Unsigned 16
  -- ^ Which port they sent it from.
  }
  deriving (Generic, NFDataX, ShowX, Eq)

emptyRxMeta :: RxMeta
emptyRxMeta = RxMeta{rxLength = 0, rxSrcIp = repeat 0, rxSrcPort = 0}

-- | Where the receive writer is within a packet.
data RxState = RxState
  { rxWord :: Index SlotWords
  -- ^ Next word to write within the slot.
  , rxBytes :: Unsigned 16
  -- ^ Payload bytes written so far.
  , rxSpoiled :: Bool
  -- ^ This packet has overrun its slot, or arrived with nowhere to go. It is
  -- still consumed off the stream -- a packet has to be drained whether it is
  -- wanted or not -- but nothing is committed at the end of it.
  }
  deriving (Generic, NFDataX, ShowX, Eq)

initRxState :: RxState
initRxState = RxState{rxWord = 0, rxBytes = 0, rxSpoiled = False}

{- | What one cycle of the receive writer does.

Returns the next state, the RAM write (relative to the slot), and, on the last
transfer of a packet that is worth keeping, the metadata to commit.
-}
rxStep ::
  -- | Is the ring full?
  Bool ->
  RxState ->
  Maybe (PacketStreamM2S WordBytes (IPv4Address, UdpHeaderLite)) ->
  (RxState, Maybe (Index SlotWords, BitVector WordBytes, BitVector 32), Maybe RxMeta)
rxStep _ st Nothing = (st, Nothing, Nothing)
rxStep ringFull st (Just transfer) = (next, write, commit)
 where
  atEnd = isJust transfer._last

  -- Bytes carried by this transfer: a full word unless it is the last one.
  valid :: Unsigned 16
  valid = maybe (natToNum @WordBytes) (fromIntegral . toInteger) transfer._last

  -- Spoiled if it already was, if the stack gave up on it, if there is nowhere
  -- to put it, or if it does not fit.
  spoiled = st.rxSpoiled || transfer._abort || ringFull || st.rxWord == maxBound && not atEnd

  write
    | spoiled = Nothing
    | otherwise = Just (st.rxWord, maxBound, fromLanes transfer._data)

  next
    | atEnd = initRxState
    | otherwise =
        RxState
          { rxWord = satSucc SatBound st.rxWord
          , rxBytes = st.rxBytes + valid
          , rxSpoiled = spoiled
          }

  {- The length comes from the UDP header, not from counting what arrived.

  Those are not the same number. Ethernet pads every frame to 60 bytes, and with
  a 14-byte Ethernet header, a 20-byte IP header and an 8-byte UDP header that
  means any payload under 18 bytes arrives with padding after it. Counting bytes
  reports 18 for all of them, which is how a 7-byte datagram comes back as 18.
  The UDP length field is what says where the payload actually ends.

  Taking the smaller of the two rather than trusting the header outright: a
  header claiming more than arrived would otherwise have software reading bytes
  that were never received. -}
  commit
    | atEnd && not spoiled =
        let (IPv4Address src, udp) = transfer._meta
         in Just
              RxMeta
                { rxLength = min (st.rxBytes + valid) udp._udplPayloadLength
                , rxSrcIp = src
                , rxSrcPort = udp._udplSrcPort
                }
    | otherwise = Nothing

-- * Transmit

-- | Where the transmitter is.
data TxState
  = -- | Nothing to send.
    TxIdle
  | -- | Waiting a cycle for the RAM to produce this word.
    TxFetch (Index TxWords)
  | -- | Offering this word to the stack, until it is taken.
    TxEmit (Index TxWords)
  deriving (Generic, NFDataX, ShowX, Eq)

{- | One cycle of the transmitter.

Two cycles per word: one to put the address on the memory, one to offer what
comes back. That is 16 bits per cycle at 48 MHz, an order of magnitude more than
a 100 Mbit link can take, so the simplicity is free.
-}
txStep ::
  TxState ->
  -- | Software asked to send.
  Bool ->
  -- | Index of the last word to send.
  Index TxWords ->
  -- | Valid bytes in that last word.
  Index (WordBytes + 1) ->
  -- | Data from the transmit memory.
  BitVector 32 ->
  -- | Where the packet is going.
  (IPv4Address, UdpHeaderLite) ->
  -- | Backpressure from the stack.
  PacketStreamS2M ->
  ( TxState
  , Maybe (PacketStreamM2S WordBytes (IPv4Address, UdpHeaderLite))
  , Index TxWords
  )
txStep st send lastWord lastBytes ramDat meta (PacketStreamS2M ready) = (next, out, rdAddr)
 where
  rdAddr = case st of
    TxIdle -> 0
    TxFetch i -> i
    TxEmit i -> i

  atEnd i = i == lastWord

  out = case st of
    TxEmit i ->
      Just
        PacketStreamM2S
          { _data = toLanes ramDat
          , _last = if atEnd i then Just lastBytes else Nothing
          , _meta = meta
          , _abort = False
          }
    _ -> Nothing

  next = case st of
    TxIdle
      | send -> TxFetch 0
      | otherwise -> TxIdle
    TxFetch i -> TxEmit i
    TxEmit i
      | not ready -> TxEmit i
      | atEnd i -> TxIdle
      | otherwise -> TxFetch (satSucc SatBound i)

-- * The device

-- | A request from the bus against one of the buffers: read an index, or write
-- an index with a byte mask.
type BufReq n = Either (Index n) (Index n, BitVector WordBytes, BitVector 32)

-- | Everything the register block hands to the datapath.
data EthRegs = EthRegs
  { regMac :: Vec 6 (BitVector 8)
  , regIp :: Vec 4 (BitVector 8)
  , regMask :: Vec 4 (BitVector 8)
  , regLocalPort :: Unsigned 16
  , regRxPop :: Bool
  -- ^ A write to @rx_pop@ happened this cycle.
  , regTxSend :: Bool
  -- ^ A write to @tx_send@ happened this cycle.
  , regTxLength :: Unsigned 16
  , regTxDstIp :: Vec 4 (BitVector 8)
  , regTxDstPort :: Unsigned 16
  }
  deriving (Generic, NFDataX, ShowX)

{- | The register block: everything the CPU can address, and nothing else.

Split out from the datapath because the two are wired differently -- this is all
circuit notation over the memory map, while the datapath is plain signals feeding
memories -- and because keeping it separate is what makes the memory map legible
in one screen.
-}
ethernetBusC ::
  forall dom aw.
  ( HasCallStack
  , HiddenClockResetEnable dom
  , KnownNat aw
  , ?byteOrder :: ByteOrder
  ) =>
  Circuit
    ( (ToConstBwd Mm, Wishbone dom 'Standard aw WordBytes)
    , CSignal dom (Index (RxSlots + 1))
    , CSignal dom RxMeta
    , CSignal dom Bool
    )
    ( CSignal dom EthRegs
    , ReqResp dom (BufReq SlotWords) (BitVector 32)
    , ReqResp dom (BufReq TxWords) (BitVector 32)
    )
ethernetBusC = circuit $ \(wb, Fwd rxAvail, Fwd rxMeta, Fwd txBusy) -> do
  [ macSlot
    , ipSlot
    , maskSlot
    , portSlot
    , availSlot
    , lenSlot
    , srcIpSlot
    , srcPortSlot
    , popSlot
    , txLenSlot
    , txIpSlot
    , txPortSlot
    , sendSlot
    , busySlot
    , rxBufSlot
    , txBufSlot
    ] <-
    deviceWbI (deviceConfig "Ethernet") -< wb

  Fwd mac <- registerWbI_' macCfg (repeat 0) -< macSlot
  Fwd ip <- registerWbI_' ipCfg (repeat 0) -< ipSlot
  Fwd mask <- registerWbI_' maskCfg (repeat 0) -< maskSlot
  Fwd localPort <- registerWbI_' portCfg 0 -< portSlot
  Fwd txLength <- registerWbI_' txLenCfg 0 -< txLenSlot
  Fwd txDstIp <- registerWbI_' txIpCfg (repeat 0) -< txIpSlot
  Fwd txDstPort <- registerWbI_' txPortCfg 0 -< txPortSlot

  registerWbI_ availCfg 0 -< (availSlot, Fwd (Just <$> rxAvail))
  registerWbI_ lenCfg 0 -< (lenSlot, Fwd (Just . rxLength <$> rxMeta))
  registerWbI_ srcIpCfg (repeat 0) -< (srcIpSlot, Fwd (Just . rxSrcIp <$> rxMeta))
  registerWbI_ srcPortCfg 0 -< (srcPortSlot, Fwd (Just . rxSrcPort <$> rxMeta))
  registerWbI_ busyCfg False -< (busySlot, Fwd (Just <$> txBusy))

  Fwd rxPop <- writePulse popCfg -< popSlot
  Fwd txSend <- writePulse sendCfg -< sendSlot

  rxReq <- addressableBytesWb @SlotWords rxBufCfg -< rxBufSlot
  txReq <- addressableBytesWb @TxWords txBufCfg -< txBufSlot

  let
    regs =
      EthRegs
        <$> mac
        <*> ip
        <*> mask
        <*> localPort
        <*> rxPop
        <*> txSend
        <*> txLength
        <*> txDstIp
        <*> txDstPort
  idC -< (Fwd regs, rxReq, txReq)
 where
  readOnly cfg = cfg{Reg.access = ReadOnly}
  writeOnly cfg = cfg{Reg.access = WriteOnly}

  macCfg = registerConfig "mac" "Our MAC address, low byte first"
  ipCfg = registerConfig "ip" "Our IPv4 address"
  maskCfg = registerConfig "subnet_mask" "Our IPv4 subnet mask"
  portCfg = registerConfig "local_port" "UDP port we listen on"
  availCfg = readOnly $ registerConfig "rx_available" "Received packets waiting to be read"
  lenCfg = readOnly $ registerConfig "rx_length" "Payload bytes in the packet at the head of the ring"
  srcIpCfg = readOnly $ registerConfig "rx_src_ip" "Who sent the packet at the head of the ring"
  srcPortCfg = readOnly $ registerConfig "rx_src_port" "Which port they sent it from"
  popCfg = writeOnly $ registerConfig "rx_pop" "Write anything to release the head packet"
  txLenCfg = registerConfig "tx_length" "Payload bytes to transmit"
  txIpCfg = registerConfig "tx_dst_ip" "Where to send it"
  txPortCfg = registerConfig "tx_dst_port" "Which port to send it to"
  sendCfg = writeOnly $ registerConfig "tx_send" "Write anything to transmit the buffer"
  busyCfg = readOnly $ registerConfig "tx_busy" "A transmission is still in progress"
  rxBufCfg = readOnly $ registerConfig "rx_buffer" "Payload of the packet at the head of the ring"
  txBufCfg = registerConfig "tx_buffer" "Payload to transmit"

{- | A register software writes to but never reads, used purely for its edge:
the value is irrelevant, the write itself is the command.
-}
writePulse ::
  forall dom aw wordSize.
  (HiddenClockResetEnable dom, RegisterWbConstraints Bool dom wordSize aw) =>
  RegisterConfig ->
  Circuit (RegisterWb dom aw wordSize) (CSignal dom Bool)
writePulse cfg = circuit $ \slot -> do
  (_val, Fwd activity) <- registerWbI cfg False -< (slot, Fwd (pure Nothing))
  idC -< Fwd (isWrite <$> activity)
 where
  isWrite (Just (BusWrite _)) = True
  isWrite _ = False

{- | 'registerWbI' for a register only software writes, whose value the hardware
reads. The common case for configuration.
-}
registerWbI_' ::
  forall a dom aw wordSize.
  (HiddenClockResetEnable dom, RegisterWbConstraints a dom wordSize aw) =>
  RegisterConfig ->
  a ->
  Circuit (RegisterWb dom aw wordSize) (CSignal dom a)
registerWbI_' cfg initial = circuit $ \slot -> do
  (Fwd val, _activity) <- registerWbI cfg initial -< (slot, Fwd (pure Nothing))
  idC -< Fwd val

{- | Service bus requests against one of the memories.

A read costs a cycle, because that is what a block RAM costs, so the request is
held for one and answered on the next. A write is answered immediately -- there
is nothing to wait for, and the value in the response is ignored.

@base@ is added to every address, which is what lets a window that is fixed in
the memory map look at a slot that moves through a ring.
-}
bufferWindow ::
  forall nWords nAddrs dom.
  ( HiddenClockResetEnable dom
  , KnownNat nWords
  , KnownNat nAddrs
  , 1 <= nWords
  , 1 <= nAddrs
  ) =>
  Signal dom (Index nAddrs) ->
  Signal dom (BitVector 32) ->
  Signal dom (Maybe (BufReq nWords)) ->
  (Signal dom (Maybe (BitVector 32)), Signal dom (Index nAddrs))
bufferWindow base ramOut req = (resp, rdAddr)
 where
  reading = register False (isRead <$> req .&&. (not <$> reading))

  resp =
    mux
      reading
      (Just <$> ramOut)
      (mux (isWrite <$> req) (pure (Just 0)) (pure Nothing))

  rdAddr = liftA2 addrOf base req

  isRead (Just (Left _)) = True
  isRead _ = False

  isWrite (Just (Right{})) = True
  isWrite _ = False

  addrOf b (Just (Left ix)) = satAdd SatWrap b (widen ix)
  addrOf b (Just (Right (ix, _, _))) = satAdd SatWrap b (widen ix)
  addrOf b Nothing = b

  widen :: Index nWords -> Index nAddrs
  widen = fromIntegral . toInteger

{- | The Ethernet device: registers, a receive ring and a transmit buffer.

The bus side is 'ethernetBusC'; this ties it to the two memories and to the
packet stream. It is written as a plain 'Circuit' rather than in circuit notation
because the receive writer, the transmit reader and the two bus windows all share
memories, and that is a knot of signals rather than a chain of components.
-}
ethernetWb ::
  forall dom aw.
  ( HasCallStack
  , HiddenClockResetEnable dom
  , KnownNat aw
  , ?byteOrder :: ByteOrder
  ) =>
  Circuit
    ( (ToConstBwd Mm, Wishbone dom 'Standard aw WordBytes)
    , PacketStream dom WordBytes (IPv4Address, UdpHeaderLite)
    )
    ( PacketStream dom WordBytes (IPv4Address, UdpHeaderLite)
    , CSignal dom (MacAddress, (IPv4Address, IPv4SubnetMask), Unsigned 16)
    )
ethernetWb = Circuit go
 where
  Circuit busC = ethernetBusC

  go ((wbIn, rxFwd), (txBwd, _)) = ((wbOut, rxBwd), (txFwd, cfg))
   where
    ((wbOut, _, _, _), (regs, rxReq, txReq)) =
      busC ((wbIn, rxAvailable, rxMetaOut, txBusy), ((), rxResp, txResp))

    cfg = toCfg <$> regs
    toCfg r =
      ( MacAddress r.regMac
      , (IPv4Address r.regIp, IPv4SubnetMask r.regMask)
      , r.regLocalPort
      )

    -- ---------------------------------------------------------------- receive

    -- Never stall the stack. A packet with nowhere to go is drained and dropped
    -- rather than backed up into the MAC, where it would eventually be truncated
    -- anyway and with worse consequences.
    rxBwd = pure (PacketStreamS2M True)

    ringFull = (== maxBound) <$> rxAvailable

    (rxStateNext, rxWrite, rxCommit) =
      unbundle (rxStep <$> ringFull <*> rxStateR <*> rxFwd)
    rxStateR = register initRxState rxStateNext

    committing = isJust <$> rxCommit
    popping = (regRxPop <$> regs) .&&. fmap (/= 0) rxAvailable

    rxWrSlot = register (0 :: Index RxSlots) rxWrSlot'
    rxWrSlot' = mux committing (satSucc SatWrap <$> rxWrSlot) rxWrSlot

    rxRdSlot = register (0 :: Index RxSlots) rxRdSlot'
    rxRdSlot' = mux popping (satSucc SatWrap <$> rxRdSlot) rxRdSlot

    rxAvailable = register (0 :: Index (RxSlots + 1)) rxAvailable'
    rxAvailable' = countUpdate <$> committing <*> popping <*> rxAvailable

    countUpdate True False n = satSucc SatBound n
    countUpdate False True n = satPred SatBound n
    countUpdate _ _ n = n

    rxMetas = register (repeat @RxSlots emptyRxMeta) rxMetas'
    rxMetas' = metaUpdate <$> rxCommit <*> rxWrSlot <*> rxMetas
    metaUpdate (Just m) slot ms = replace slot m ms
    metaUpdate Nothing _ ms = ms
    rxMetaOut = (!!) <$> rxMetas <*> rxRdSlot

    rxRamOut = byteLaneRam (SNat @RxWords) rxRamRd rxRamWr
    rxRamWr = liftA2 offsetWrite rxWrSlot rxWrite
    offsetWrite slot = fmap (\(w, m, d) -> (slotAddr slot w, m, d))

    (rxResp, rxRamRd) = bufferWindow rxBase rxRamOut rxReq
    rxBase = flip slotAddr 0 <$> rxRdSlot

    -- --------------------------------------------------------------- transmit

    txRamOut = byteLaneRam (SNat @TxWords) txRamRd txRamWr
    txRamWr = (>>= txWriteOf) <$> txReq
    txWriteOf (Right w) = Just w
    txWriteOf _ = Nothing

    (txResp, txWinRd) = bufferWindow (pure 0) txRamOut txReq

    -- The transmitter owns the read port while it is sending; the CPU has it the
    -- rest of the time. Reading the transmit buffer mid-send is therefore not
    -- meaningful, and there is no reason to do it.
    txRamRd = mux txBusy txEngineRd txWinRd

    (txStateNext, txFwd, txEngineRd) =
      unbundle
        ( txStep
            <$> txStateR
            <*> (regTxSend <$> regs)
            <*> txLastWord
            <*> txLastBytes
            <*> txRamOut
            <*> txMeta
            <*> txBwd
        )
    txStateR = register TxIdle txStateNext
    txBusy = (/= TxIdle) <$> txStateR

    txLastWord = lastWordOf . regTxLength <$> regs
    lastWordOf len = fromIntegral (max 1 ((toInteger len + 3) `div` 4) - 1) :: Index TxWords

    txLastBytes = lastBytesOf . regTxLength <$> regs
    lastBytesOf len = case len `mod` 4 of
      0 -> maxBound
      n -> fromIntegral (toInteger n)

    txMeta = metaOf <$> regs
    metaOf r =
      ( IPv4Address r.regTxDstIp
      , UdpHeaderLite
          { _udplSrcPort = r.regLocalPort
          , _udplDstPort = r.regTxDstPort
          , _udplPayloadLength = r.regTxLength
          }
      )

-- | Address of word @w@ within slot @s@ of the receive ring.
slotAddr :: Index RxSlots -> Index SlotWords -> Index RxWords
slotAddr s w =
  fromIntegral (fromIntegral s * natToNum @SlotWords + fromIntegral w :: Int)
