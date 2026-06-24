-- SPDX-FileCopyrightText: 2022 Google LLC
--
-- SPDX-License-Identifier: Apache-2.0
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE UndecidableInstances #-}

module SharedTypes (
  Bytes,
  Byte,
  ByteEnable,
  Paddable,
  Located,
  LocatedByte,
  Regs,
  VexBone,
  VexBoneMm,
  RegisterBank (..),
  getRegsBe,
  getDataBe,
  updateM2SAddr,
) where

import Clash.Prelude

import Clash.Class.BitPackC (ByteOrder (..), Bytes)
import Data.Constraint
import Data.Constraint.Nat.Lemmas
import Protocols (ToConstBwd)
import Protocols.Experimental.Wishbone
import Protocols.MemoryMap (Mm)

-- | Polymorphic record update of 'addr'.
updateM2SAddr ::
  BitVector addressWidthNew ->
  WishboneM2S addressWidthOld selWidth ->
  WishboneM2S addressWidthNew selWidth
updateM2SAddr newAddr m@WishboneM2S{} =
  WishboneM2S
    { addr = newAddr
    , burstTypeExtension = m.burstTypeExtension
    , busCycle = m.busCycle
    , busSelect = m.busSelect
    , cycleTypeIdentifier = m.cycleTypeIdentifier
    , lock = m.lock
    , strobe = m.strobe
    , writeData = m.writeData
    , writeEnable = m.writeEnable
    }

-- | A single byte.
type Byte = BitVector 8

-- | A BitVector that contains one bit per byte in the BitSize of a.
type ByteEnable a = BitVector (Regs a 8)

-- | Constraints required to add padding to @a@.
type Paddable a = (BitPack a, NFDataX a)

{- | @Located i x@ is a datatype that indicates that data @x@ has a relation with
@Index i@. Example usage: write operation of type D to a blockRam with 'i' addresses
can be described as: @Located i D@

@writeData@ has a relation with @Index maxIndex@.
-}
type Located maxIndex writeData = (Index maxIndex, writeData)

-- | 'Byte' has a relation with @Index maxIndex@.
type LocatedByte maxIndex = Located maxIndex Byte

-- | Padding bits added when a is stored in multiples of bw bits.
type Pad a bw = (Regs a bw * bw) - BitSize a

-- | Amount of bw sized registers required to store a.
type Regs a bw = DivRU (BitSize a) bw

-- | 'Wishbone' hardcoded to the 'Standard' protocol and a 32-bit bus width.
type VexBone dom addressWidth = Wishbone dom 'Standard addressWidth 4

{- | A memory map paired with 'Wishbone' hardcoded to the 'Standard' protocol
and a 32-bit bus width.
-}
type VexBoneMm dom addressWidth = (ToConstBwd Mm, VexBone dom addressWidth)

-- | Stores any arbitrary datatype as a vector of registers.
newtype RegisterBank regSize content (byteOrder :: ByteOrder)
  = RegisterBank (Vec (Regs content regSize) (BitVector regSize))
  deriving (Generic)

instance
  (KnownNat regSize, 1 <= regSize, BitPack content) =>
  BitPack (RegisterBank regSize content byteOrder)
  where
  type
    BitSize (RegisterBank regSize content byteOrder) =
      Regs content regSize * regSize
  pack (RegisterBank vec) = pack vec
  unpack bv = RegisterBank (unpack bv)

deriving newtype instance
  ( KnownNat regSize
  , 1 <= regSize
  , Paddable content
  , NFDataX (RegisterBank regSize content byteOrder)
  ) =>
  NFDataX (RegisterBank regSize content byteOrder)

deriving newtype instance
  (KnownNat regSize, ShowX (RegisterBank regSize content byteOrder)) =>
  ShowX (RegisterBank regSize content byteOrder)

-- | Transforms a to _RegisterBank_.
getRegsBe ::
  forall bw a. (Paddable a, KnownNat bw, 1 <= bw) => a -> RegisterBank bw a 'BigEndian
getRegsBe a = case timesDivRU @bw @(BitSize a) of
  Dict -> RegisterBank (bitCoerce (0 :: BitVector (Pad a bw), a))

-- | Transforms _RegisterBank_ to a.
getDataBe ::
  forall bw a. (Paddable a, KnownNat bw, 1 <= bw) => RegisterBank bw a 'BigEndian -> a
getDataBe (RegisterBank vec) =
  case timesDivRU @bw @(BitSize a) of
    Dict -> unpack . snd $ split @_ @(Pad a bw) @(BitSize a) (pack vec)
