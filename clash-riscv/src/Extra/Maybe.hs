-- SPDX-FileCopyrightText: 2023 Google LLC
--
-- SPDX-License-Identifier: Apache-2.0
module Extra.Maybe where

import Clash.Prelude

{- | Returns 'Just a' when the boolean is 'True', or 'Nothing' when 'False'.

* Examples:

   >>> toMaybe True 5
   Just 5

   >>> toMaybe False "Hello"
   Nothing
-}
toMaybe :: Bool -> a -> Maybe a
toMaybe True a = Just a
toMaybe False _ = Nothing
