module Workshop.Memory where

-- prelude imports
import Clash.Prelude hiding (Exp)

-- external imports
import DoubleBufferedRam (
  ContentType,
  blockRamByteAddressable,
  blockRamByteAddressableU,
 )
import SharedTypes (Bytes)
import Data.Constraint (Dict (Dict))
import Data.Constraint.Nat.Lemmas (cancelMulDiv)
import GHC.Stack (HasCallStack)
import Protocols
import Protocols.Experimental.Wishbone
import Protocols.MemoryMap.Registers.WishboneStandard (
  DeviceConfig (registered),
  addressableBytesWb,
  deviceConfig,
  deviceWbI,
  registerConfig,
 )

-- qualified imports

import qualified Protocols.ReqResp as ReqResp
import qualified Protocols.MemoryMap as Mm


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
  Circuit (ToConstBwd Mm.Mm, Wishbone dom 'Standard aw nBytes) ()
wbStorage memoryName SNat initContent =
  circuit $ \wbMm -> do
    [wb0] <- deviceWbI (deviceConfig memoryName){registered = False} -< wbMm
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
