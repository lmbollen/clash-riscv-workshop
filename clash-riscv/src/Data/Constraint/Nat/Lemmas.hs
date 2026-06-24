-- SPDX-FileCopyrightText: 2022 Google LLC
--
-- SPDX-License-Identifier: Apache-2.0
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoStarIsType #-}

{- | The functions in this module enable us introduce trivial constraints that are
not solved by the constraint solver.
-}
module Data.Constraint.Nat.Lemmas (
  cancelMulDiv,
  timesDivRU,
) where

import Data.Constraint (Dict (..))
import Data.Type.Equality (type (~))
import GHC.TypeLits.Extra (DivRU)
import GHC.TypeNats (Div, type (*), type (+), type (-), type (<=))
import Unsafe.Coerce (unsafeCoerce)

-- | b <= ceiling(b/a)*a
timesDivRU :: forall a b. (1 <= a) => Dict (b <= (Div (b + (a - 1)) a * a))
timesDivRU = unsafeCoerce (Dict :: Dict (0 <= 0))

{- | Postulates that multiplying some number /a/ by some constant /b/, and
subsequently dividing that result by /b/ equals /a/.
-}
cancelMulDiv :: forall a b. (1 <= b) => Dict (DivRU (a * b) b ~ a)
cancelMulDiv = unsafeCoerce (Dict :: Dict (0 ~ 0))
