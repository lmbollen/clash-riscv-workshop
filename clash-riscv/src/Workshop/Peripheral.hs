{-# LANGUAGE ImplicitParams #-}

module Workshop.Peripheral where

import Clash.Prelude

import Clash.Class.BitPackC (ByteOrder)

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
