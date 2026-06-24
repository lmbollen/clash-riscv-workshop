module Workshop.Utils where

import Prelude

import Control.Exception (throwIO)
import System.Directory (doesFileExist, getCurrentDirectory)
import System.FilePath (isDrive, takeDirectory, (</>))

import Clash.Prelude
import Clash.Sized.Vector (unsafeFromList)

import Data.Elf

import DoubleBufferedRam (ContentType (Vec))
import SharedTypes (Bytes)

import qualified Data.ByteString as BS
import qualified Data.IntMap.Strict as I
import qualified Data.List as L

{- | Read a RISC-V ELF and split it into instruction- and data-memory images
sized for the SoC's block RAMs.

Loadable executable segments become instruction memory, everything else data
memory. Each is packed into little-endian 32-bit words (placed from its segment
base, which the linker put at the memory's address) and padded to the depth.
-}
loadElfMemories ::
  forall depthI depthD.
  (KnownNat depthI, KnownNat depthD) =>
  FilePath ->
  IO (ContentType depthI (Bytes 4), ContentType depthD (Bytes 4))
loadElfMemories path = do
  contents <- BS.readFile path
  let (iBytes, dBytes) = readSegments contents
  pure (Vec (toWords iBytes), Vec (toWords dBytes))

-- | Fold the ELF's loadable segments into (instruction, data) byte maps keyed by
-- absolute address.
readSegments :: BS.ByteString -> (I.IntMap (BitVector 8), I.IntMap (BitVector 8))
readSegments contents = L.foldr go (mempty, mempty) (elfSegments (parseElf contents))
 where
  go seg acc@(is, ds)
    | elfSegmentType seg /= PT_LOAD = acc
    | PF_X `elem` elfSegmentFlags seg =
        (addData (elfSegmentPhysAddr seg) (toBytes (elfSegmentData seg)) is, ds)
    | otherwise =
        let segData = elfSegmentData seg
            fileSize = fromIntegral (BS.length segData)
            memSize = fromIntegral (elfSegmentMemSize seg)
            dat = toBytes segData L.++ L.replicate (memSize - fileSize) 0
         in (is, addData (elfSegmentPhysAddr seg) dat ds)

  toBytes = L.map pack . BS.unpack
  addData (fromIntegral -> start) dat mem = I.fromList (L.zip [start ..] dat) <> mem

-- | Flatten a byte map (from its lowest address) into LE 32-bit words, padded
-- with zeros to exactly @n@ words.
toWords ::
  forall n. (KnownNat n) => I.IntMap (BitVector 8) -> Vec n (BitVector 32)
toWords m = unsafeFromList (L.take (natToNum @n) (pack4 (flatten m) L.++ L.repeat 0))
 where
  flatten im = case I.toAscList im of
    [] -> []
    ((k0, v0) : rest) -> v0 : gaps k0 rest
  gaps _ [] = []
  gaps prev ((k, v) : xs) = L.replicate (k - prev - 1) 0 L.++ (v : gaps k xs)

  pack4 [] = []
  pack4 [a] = pack4 [a, 0, 0, 0]
  pack4 [a, b] = pack4 [a, b, 0, 0]
  pack4 [a, b, c] = pack4 [a, b, c, 0]
  -- low address -> low bits
  pack4 (a : b : c : d : rest) = pack (d, c, b, a) : pack4 rest


{- | Search upwards from the current working directory until a directory
containing the given file is found. Throws if it reaches the filesystem root
without finding it.
-}
findParentContaining :: String -> IO FilePath
findParentContaining filename = goUp =<< getCurrentDirectory
 where
  goUp :: FilePath -> IO FilePath
  goUp path
    | isDrive path = throwIO $ userError $ "Could not find " <> filename
    | otherwise = do
        exists <- doesFileExist (path </> filename)
        if exists
          then return path
          else goUp (takeDirectory path)
