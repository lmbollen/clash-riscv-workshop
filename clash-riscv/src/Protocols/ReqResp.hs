{-# LANGUAGE LambdaCase #-}

{- | @Protocols.ReqResp@: re-exports @clash-protocols@'s
'Protocols.Experimental.ReqResp' and adds the block-RAM helper
'fromBlockRamWithMask', without pulling in @Protocols.BiDf@.
-}
module Protocols.ReqResp (
  module Protocols.Experimental.ReqResp,
  fromBlockRamWithMask,
) where

import Clash.Prelude
import Data.Maybe (fromMaybe, isJust)
import Protocols
import Protocols.Experimental.ReqResp

import qualified Clash.Prelude as C

{- | Given a 'blockRam' primitive, create a circuit that offers a 'ReqResp' interface to access
the primitive using 'ReqResp' for the read channel and 'Df' for the write channel.

If you use 'ReqResp' for the write channel, you can use 'requests' to convert it to a 'Df' stream
to be used with this circuit.
-}
fromBlockRamWithMask ::
  (C.KnownDomain dom, C.HiddenClock dom, C.HiddenReset dom, Num addr, C.KnownNat words) =>
  ( C.Signal dom addr ->
    C.Signal dom (Maybe (addr, C.BitVector (words C.* 8))) ->
    C.Signal dom (C.BitVector words) ->
    C.Signal dom (C.BitVector (words C.* 8))
  ) ->
  Circuit
    ( ReqResp dom addr (C.BitVector (words C.* 8))
    , Df dom (addr, C.BitVector words, C.BitVector (words C.* 8))
    )
    ()
fromBlockRamWithMask primitive = Circuit go
 where
  writeBwd = pure $ Ack True
  go ((readFwd, writeFwd), _) = ((readBwd, writeBwd), ())
   where
    -- Separate the write data and byte enables
    writeData = fmap (>>= \(addr, _mask, dat) -> Just (addr, dat)) writeFwd
    byteEnables = fmap (\case Just (_, mask, _) -> mask; Nothing -> 0) writeFwd

    readData = primitive (fromMaybe 0 <$> readFwd) writeData byteEnables

    -- Reading takes 1 cycle so we run at half speed
    readValid = C.withEnable C.enableGen C.register False (fmap isJust readFwd C..&&. fmap not readValid)
    readBwd = liftA2 (\v d -> if v then Just d else Nothing) readValid readData
