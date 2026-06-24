{- | Minimal local @Clash.Sized.Vector.Extra@ for the workshop.

Provides 'incrementWithBlacklist', which
'Workshop.Cpu' uses to generate interconnect prefixes. @guarded@ is inlined so we
don't depend on the @extra@ package.
-}
module Clash.Sized.Vector.Extra (incrementWithBlacklist) where

import Clash.Prelude
import Data.Maybe (fromJust)
import GHC.Stack (HasCallStack)

{- | Generates a vector of incrementing numbers, skipping values that are in the
blacklist. Throws an error if it can't produce enough unique values.

>>> incrementWithBlacklist (1 :> 3 :> Nil) :: Vec 3 (Unsigned 8)
0 :> 2 :> 4 :> Nil
-}
incrementWithBlacklist ::
  forall n m x.
  (HasCallStack, KnownNat m, KnownNat n, KnownNat x) =>
  Vec m (Unsigned x) ->
  Vec n (Unsigned x)
incrementWithBlacklist blackList
  | fromIntegral (maxBound :: Unsigned x) < (natToNum @(n + m) - 1 :: Integer) = err
  | otherwise = fmap fromJust $ takeI $ packVec results
 where
  err = clashCompileError "incrementWithBlacklist: Not enough unique values possible"
  candidates = iterateI @(n + m) go (Just minBound)

  go (Just n) = if n == maxBound then Nothing else Just (n + 1)
  go Nothing = Nothing

  results = fmap (>>= (guarded (`notElem` blackList))) candidates

  guarded p a = if p a then Just a else Nothing

  packVec = foldr f (repeat @(n + m) Nothing)
   where
    f (Just a) acc = Just a +>> acc
    f Nothing acc = acc
