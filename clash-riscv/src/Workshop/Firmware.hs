-- | Loading compiled firmware (a RISC-V ELF) into the SoC's memories.
module Workshop.Firmware (loadElfMemories, loadElfMemoriesTH) where

import Clash.Prelude
import Clash.Sized.Vector (unsafeFromList)

import Data.Elf

import DoubleBufferedRam (ContentType (ByteLanes, Vec))
import SharedTypes (Bytes)

import Language.Haskell.TH (Q, reportWarning, runIO)
import Language.Haskell.TH.Syntax (addDependentFile)

import qualified Language.Haskell.TH as TH
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Workshop.Utils (findParentContaining)

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

{- | The compile-time counterpart of 'loadElfMemories': read the ELF while the
Clash design is being compiled and splice the two memory images straight into
the design, so that the block RAMs come up holding the firmware and the CPU has
something to run the moment the FPGA leaves reset.

@path@ is relative to the repository root (the directory holding
@cabal.project@). The splice has type

> Maybe (ContentType depthI (Bytes 4), ContentType depthD (Bytes 4))

which is exactly what 'Workshop.Cpu.PeConfig'\'s @initI@ / @initD@ want. It is a
'Maybe' because the firmware is built /after/ the Clash side (the Rust build
needs @memory_maps/Soc.json@, which compiling this library produces): on a clean
tree the ELF does not exist yet, and rather than break the build this yields
'Nothing' and warns. Build the firmware and recompile to bake it in.
-}
loadElfMemoriesTH ::
  forall depthI depthD.
  SNat depthI ->
  SNat depthD ->
  FilePath ->
  Q TH.Exp
loadElfMemoriesTH SNat SNat path = do
  elfPath <- runIO $ do
    root <- findParentContaining "cabal.project"
    pure (root </> path)
  present <- runIO (doesFileExist elfPath)
  if not present
    then do
      reportWarning $
        "loadElfMemoriesTH: no ELF at "
          <> elfPath
          <> ". The instruction and data memories will be left empty, so the CPU"
          <> " has nothing to run. Build the firmware (cd firmware && cargo build"
          <> " --release) and recompile to bake it in."
      [|Nothing|]
    else do
      -- Tell GHC this module's output depends on the ELF's *contents*. Without
      -- this the splice is only re-run when this source file changes, so
      -- rebuilding the firmware leaves a stale image compiled in -- which is
      -- silent, and looks exactly like a broken SoC. (It bit us when the memory
      -- map moved: the design kept the previous build's peripheral addresses.)
      addDependentFile elfPath
      contents <- runIO (BS.readFile elfPath)
      let (iBytes, dBytes) = readSegments contents
      [|
        Just
          ( $(byteLanesTH (toWords @depthI iBytes))
          , $(byteLanesTH (toWords @depthD dBytes))
          )
        |]

{- | Split a vector of words into one 'MemBlob' per byte lane of the word, as a
'ByteLanes' expression.

The split is done here, in plain Haskell at compile time, precisely so that
Clash never has to constant-fold it -- see the 'DoubleBufferedRam.ByteLanes'
documentation for why that matters.

Each lane is a 'MemBlob' rather than a 'Vec' literal. A 'Vec' of a thousand-odd
elements is a correspondingly deeply nested chain of @:>@, and walking it
overflows the compiler's stack; a 'MemBlob' is a packed blob that Clash renders
straight into the HDL's memory initialiser.

The lane order is taken straight from 'bitCoerce', which is exactly what
'SharedTypes.getRegsBe' uses, so the lanes line up with the byte enables that
'DoubleBufferedRam.splitWriteInBytes' generates. (That puts the most significant
byte in lane 0.) Deriving it this way rather than by hand-rolled shifting means
the two cannot drift apart.
-}
byteLanesTH ::
  forall n.
  (KnownNat n) =>
  Vec n (Bytes 4) ->
  Q TH.Exp
byteLanesTH ws = [|ByteLanes $(L.foldr consLane [|Nil|] lanes)|]
 where
  lanes :: [[BitVector 8]]
  lanes = L.transpose (L.map (toList . toLanes) (toList ws))

  toLanes :: Bytes 4 -> Vec 4 (BitVector 8)
  toLanes = bitCoerce

  consLane lane acc = [|$(memBlobTH Nothing lane) :> $acc|]

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
