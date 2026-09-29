-- SPDX-FileCopyrightText: 2022 Google LLC
--
-- SPDX-License-Identifier: Apache-2.0
module DoubleBufferedRam (
  ContentType (..),
  blockRamByteAddressable,
  blockRamByteAddressableU,
  wbStorage,
) where

import Clash.Prelude

import Protocols (Circuit, ToConstBwd, (<|))
import Protocols.Experimental.Wishbone
import Protocols.MemoryMap (Mm)

import Extra.Maybe
import SharedTypes
import Data.Constraint (Dict (Dict))
import Data.Constraint.Nat.Lemmas (cancelMulDiv)
import Data.Typeable
import GHC.Stack (HasCallStack)
import Protocols.MemoryMap.Registers.WishboneStandard (
  DeviceConfig (registered),
  addressableBytesWb,
  deviceConfig,
  deviceWbI,
  registerConfig,
 )

import qualified Protocols.ReqResp as ReqResp

data ContentType n a
  = Vec (Vec n a)
  | Blob (MemBlob n (BitSize a))
  | File FilePath
  | -- | Content already split across the byte lanes of the byte-addressable
    -- block RAM, in the order 'getRegsBe' produces (most significant byte
    -- first).
    --
    -- 'Vec' is the more natural way to hand over word-wide content, but
    -- 'blockRamByteAddressable' then has to split it into byte lanes itself,
    -- and Clash has to constant-fold that split at compile time. For a memory
    -- of any real size that is ruinous: a 1024-word image sent Clash past
    -- 25 GB of residency without finishing. Pre-splitting the lanes (see
    -- 'Workshop.Firmware.loadElfMemoriesTH') avoids that entirely.
    --
    -- Note the lanes are 'MemBlob's rather than a nested @ContentType n Byte@:
    -- the latter would make this type infinitely recursive (every
    -- @ContentType@ would contain another), which sends Clash into unbounded
    -- recursion the moment it tries to translate the type.
    ByteLanes (Vec (Regs a 8) (MemBlob n 8))

instance (Show a, KnownNat n, Typeable a) => Show (ContentType n a) where
  show = \case
    (Vec _) -> "Vec: " <> nAnda
    (Blob _) -> "Blob: " <> nAnda
    (File fp) -> "File: " <> nAnda <> ", filepath = " <> fp
    (ByteLanes _) -> "ByteLanes: " <> nAnda
   where
    nAnda = "(" <> show (natToNatural @n) <> " of type (" <> show (typeRep $ Proxy @a) <> "))"

{- | Accepts 'ContentType' and returns a 'blockRam' implementations initialized with
the corresponding content.
-}
initializedRam ::
  forall dom n a.
  ( HiddenClockResetEnable dom
  , KnownNat n
  , 1 <= n
  , Paddable a
  ) =>
  ContentType n a ->
  ( Signal dom (Index n) ->
    Signal dom (Maybe (Located n a)) ->
    Signal dom a
  )
initializedRam content rd wr = case content of
  Vec vec -> blockRam vec rd wr
  Blob blob -> bitCoerce <$> blockRamBlob blob rd (bitCoerce <$> wr)
  File fp -> bitCoerce <$> blockRamFile (SNat @n) fp rd (bitCoerce <$> wr)
  ByteLanes _ ->
    clashCompileError
      "initializedRam: ByteLanes content is only for the byte-addressable RAM. "

{- | Wishbone storage element with 'Circuit' interface from "Protocols.Wishbone" that
allows for word aligned reads and writes.
-}
wbStorage ::
  forall dom depth aw nBytes.
  ( HasCallStack
  , HiddenClockResetEnable dom
  , KnownNat aw
  , KnownNat nBytes
  , 1 <= nBytes
  , 1 <= depth
  ) =>
  String ->
  SNat depth ->
  Maybe (ContentType depth (Bytes nBytes)) ->
  Circuit (ToConstBwd Mm, Wishbone dom 'Standard aw nBytes) ()
wbStorage memoryName SNat initContent =
  circuit $ \wbMm -> do
    [wb0] <- deviceWbI (deviceConfig memoryName){registered = True} -< wbMm
    reqresp <- addressableBytesWb @depth regConfig -< wb0
    (reads, writes0) <- ReqResp.partitionEithers -< reqresp
    writes1 <- ReqResp.requests <| ReqResp.dropResponse 0 -< writes0
    _vecUnit <- ram -< (reads, writes1)
    idC -< ()
 where
  regConfig = registerConfig "data" "Word-addressable storage"
  ram = ReqResp.fromBlockRamWithMask
    $ case (initContent, cancelMulDiv @(nBytes) @8) of
      (Nothing, Dict) -> blockRamByteAddressableU
      (Just content, Dict) -> blockRamByteAddressable @_ @depth content
{-# OPAQUE wbStorage #-}

{- | Blockram similar to 'blockRam' with the addition that it takes a byte select signal
that controls which nBytes at the write address are updated.
-}
blockRamByteAddressable ::
  forall dom memDepth a.
  (HiddenClockResetEnable dom, KnownNat memDepth, 1 <= memDepth, Paddable a, ShowX a) =>
  -- | Initial content.
  ContentType memDepth a ->
  -- | Read address.
  Signal dom (Index memDepth) ->
  -- | Write operation.
  Signal dom (Maybe (Located memDepth a)) ->
  -- | Byte enables that determine which nBytes get replaced.
  Signal dom (ByteEnable a) ->
  -- | Data at read address (1 cycle delay).
  Signal dom a
blockRamByteAddressable initContent readAddr newEntry byteSelect =
  getDataBe @8 . RegisterBank <$> case initContent of
    Blob _ -> clashCompileError "blockRamByteAddressable: Singular MemBlobs are not supported. "
    Vec vecOfA -> go (byteRam . Vec <$> transpose (fmap getBytes vecOfA))
    -- Already split, so none of the above splitting has to be constant-folded.
    ByteLanes lanes -> go (byteRam . Blob <$> lanes)
    File _ ->
      clashCompileError
        "blockRamByteAddressable: Singular source files for initial content are not supported. "
 where
  go brams = readBytes
   where
    writeBytes = unbundle $ splitWriteInBytes <$> newEntry <*> byteSelect
    readBytes = bundle $ brams <*> writeBytes
  getBytes (getRegsBe -> RegisterBank (vec :: Vec (Regs a 8) Byte)) = vec
  byteRam = (`initializedRam` readAddr)

{- | Version of 'blockRamByteAddressable' with undefined initial contents. It is similar
to 'blockRam' with the addition that it takes a byte select signal that controls
which nBytes at the write address are updated.
-}
blockRamByteAddressableU ::
  forall dom memDepth a.
  (HiddenClockResetEnable dom, KnownNat memDepth, 1 <= memDepth, Paddable a, ShowX a) =>
  -- | Read address.
  Signal dom (Index memDepth) ->
  -- | Write operation.
  Signal dom (Maybe (Located memDepth a)) ->
  -- | Byte enables that determine which nBytes get replaced.
  Signal dom (ByteEnable a) ->
  -- | Data at read address (1 cycle delay).
  Signal dom a
blockRamByteAddressableU readAddr newEntry byteSelect =
  getDataBe @8 . RegisterBank <$> readBytes
 where
  writeBytes = unbundle $ splitWriteInBytes <$> newEntry <*> byteSelect
  readBytes = bundle $ ram readAddr <$> writeBytes
  ram = blockRamU NoClearOnReset (SNat @memDepth)

{- | Takes singular write operation (Maybe (Index maxIndex, writeData)) and splits it up
according to a supplied byteselect bitvector into a vector of byte sized write operations
(Maybe (Index maxIndex, Byte)).
-}
splitWriteInBytes ::
  forall maxIndex writeData.
  (Paddable writeData) =>
  -- | Incoming write operation.
  Maybe (Located maxIndex writeData) ->
  -- | Incoming byte enables.
  ByteEnable writeData ->
  -- | Per byte write operation.
  Vec (Regs writeData 8) (Maybe (LocatedByte maxIndex))
splitWriteInBytes (Just (addr, writeData)) byteSelect =
  case getRegsBe writeData of
    RegisterBank vec -> toMaybe <$> unpack byteSelect <*> fmap (addr,) vec
splitWriteInBytes Nothing _ = repeat Nothing
