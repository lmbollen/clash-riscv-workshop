{-# OPTIONS_GHC -fplugin Protocols.Plugin #-}

{- | Wishbone bus fabric: a single-master interconnect and a round-robin arbiter,
used by 'Workshop.Cpu'. Built directly on @clash-protocols@, with no
PacketStream/BiDf machinery.
-}
module Wishbone (
  MemoryMap,
  singleMasterInterconnectC,
  singleMasterInterconnect,
  arbiter,
  maskToMaybes,
  foldMaybes,
) where

import Clash.Prelude

import Data.Bool (bool)
import Data.Maybe (fromMaybe)
import GHC.Stack (HasCallStack)
import Protocols
import Protocols.Experimental.Wishbone

import SharedTypes (updateM2SAddr)

import qualified Data.List as L
import qualified Protocols.MemoryMap as Mm

-- | Vector of prefixes (base addresses) for the single-master interconnect.
type MemoryMap nSlaves pfxWidth = Vec nSlaves (Unsigned pfxWidth)

singleMasterInterconnectC ::
  forall dom nSlaves addrW pfxWidth nBytes.
  ( HiddenClockResetEnable dom
  , HasCallStack
  , KnownNat nSlaves
  , 1 <= nSlaves
  , KnownNat addrW
  , KnownNat pfxWidth
  , (pfxWidth <= addrW)
  , KnownNat nBytes
  , 1 <= nBytes
  ) =>
  Circuit
    (ToConstBwd Mm.Mm, Wishbone dom 'Standard addrW nBytes)
    ( Vec
        nSlaves
        ( ToConstBwd (Unsigned pfxWidth)
        , (ToConstBwd Mm.Mm, Wishbone dom 'Standard (addrW - pfxWidth) nBytes)
        )
    )
singleMasterInterconnectC = Circuit go
 where
  go ::
    ( ((), Signal dom (WishboneM2S addrW nBytes))
    , Vec
        nSlaves
        (Unsigned pfxWidth, (SimOnly Mm.MemoryMap, Signal dom (WishboneS2M nBytes)))
    ) ->
    ( (SimOnly Mm.MemoryMap, Signal dom (WishboneS2M nBytes))
    , Vec
        nSlaves
        ((), ((), Signal dom (WishboneM2S (addrW - pfxWidth) nBytes)))
    )
  go (((), m2s), unzip -> (prefixes, unzip -> (slaveMms, s2ms))) = ((SimOnly memMap, s2m), (\x -> ((), ((), x))) <$> m2ss)
   where
    -- the 4 * is needed because the addrW etc relies on a word-aligned bus,
    -- not a byte aligned bus.
    prefixToAddr prefix = 4 * (toInteger prefix `shiftL` fromInteger shift')
     where
      shift' = snatToInteger $ SNat @(addrW - pfxWidth)
    relAddrs = L.map prefixToAddr (toList prefixes)
    comps = L.zip relAddrs ((.tree) . unSimOnly <$> toList slaveMms)
    unSimOnly (SimOnly n) = n
    deviceDefs = Mm.mergeDeviceDefs ((.deviceDefs) . unSimOnly <$> toList slaveMms)
    memMap =
      Mm.MemoryMap
        { tree = Mm.Interconnect Mm.locCaller comps
        , deviceDefs = deviceDefs
        }
    (s2m, m2ss) = toSignals (singleMasterInterconnect prefixes) (m2s, s2ms)

{-# OPAQUE singleMasterInterconnect #-}

singleMasterInterconnect ::
  forall dom nSlaves addrW pfxWidth nBytes.
  ( HiddenClockResetEnable dom
  , KnownNat nSlaves
  , 1 <= nSlaves
  , KnownNat addrW
  , KnownNat pfxWidth
  , pfxWidth <= addrW
  , KnownNat nBytes
  ) =>
  MemoryMap nSlaves pfxWidth ->
  Circuit
    (Wishbone dom 'Standard addrW nBytes)
    (Vec nSlaves (Wishbone dom 'Standard (addrW - pfxWidth) nBytes))
singleMasterInterconnect (fmap pack -> config) =
  Circuit go
 where
  go (masterS, slavesS) =
    fmap unbundle . unbundle $ route <$> masterS <*> bundle slavesS

  route master@(WishboneM2S{addr, busCycle, strobe}) slaves =
    ( strictV slaves `seqX` strictV toSlaves `seqX` toMaster
    , toSlaves
    )
   where
    oneHotOrZeroSelected = fmap (== addrIndex) config
    (addrIndex :: BitVector pfxWidth, newAddr) = split addr
    toSlaves =
      (\newStrobe -> (updateM2SAddr newAddr master){strobe = strobe && newStrobe})
        <$> oneHotOrZeroSelected
    toMaster
      | busCycle && strobe =
          foldMaybes
            emptyWishboneS2M{err = True} -- master tries to access unmapped memory
            (maskToMaybes slaves oneHotOrZeroSelected)
      | otherwise = emptyWishboneS2M

  strictV :: Vec m b -> Vec m b
  strictV v
    | clashSimulation = foldl (\b a -> a `seqX` b) () v `seqX` v
    | otherwise = v

-- | Apply a mask to a vector, turning unmasked elements into 'Nothing'.
maskToMaybes :: Vec n a -> Vec n Bool -> Vec n (Maybe a)
maskToMaybes = zipWith (bool Nothing . Just)

-- | Fold 'Maybe's to a single value, preferring the leftmost 'Just'.
foldMaybes :: a -> Vec n (Maybe a) -> a
foldMaybes a Nil = a
foldMaybes dflt v@(Cons _ _) = fromMaybe dflt $ fold (<|>) v

arbiter ::
  forall dom addrW nBytes n.
  ( HiddenClockResetEnable dom
  , KnownNat addrW
  , KnownNat n
  , KnownNat nBytes
  ) =>
  Circuit
    (Vec n (Wishbone dom 'Standard addrW nBytes))
    (Wishbone dom 'Standard addrW nBytes)
arbiter = Circuit goArbitrate0
 where
  -- Bundler / unbundler for 'goArbitrate1'
  goArbitrate0 (bundle -> m2ss, s2m) = (unbundle s2ms, m2s)
   where
    (s2ms, m2s) = mealyB goArbitrate1 (Nothing @(Index n)) (m2ss, s2m)

  -- Actual worker
  goArbitrate1 current (m2ss, s2m) = (next, (s2ms, m2s))
   where
    candidate = findIndex (\m -> m.busCycle && m.strobe) m2ss
    selected = current <|> candidate
    m2s = maybe emptyWishboneM2S (m2ss !!) selected

    -- Always route the read data from the subordinate to all managers to prevent
    -- muxing. Managers will only look at the read data when they get an
    -- acknowledgement.
    emptyS2Ms = repeat (emptyWishboneS2M @0){readData = s2m.readData}
    s2ms = case selected of
      Nothing -> emptyS2Ms
      Just idx -> replace idx s2m emptyS2Ms

    -- Note that 'next' only indicates whether we're "locked" to a certain
    -- manager for the next cycle.
    next
      | hasTerminateFlag s2m = Nothing
      | otherwise = selected

