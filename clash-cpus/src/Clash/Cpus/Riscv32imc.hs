{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}

module Clash.Cpus.Riscv32imc (
  vexRiscv,
) where

import Clash.Prelude

import VexRiscv (CpuIn, CpuOut, DumpVcd, JtagIn, JtagOut)
import VexRiscv.Reset (MinCyclesReset)

import qualified VexRiscv_Riscv32imc

vexRiscv ::
  (KnownDomain dom) =>
  DumpVcd ->
  Clock dom ->
  MinCyclesReset dom 2 ->
  Signal dom CpuIn ->
  Signal dom JtagIn ->
  ( Signal dom CpuOut
  , Signal dom JtagOut
  )
vexRiscv = VexRiscv_Riscv32imc.vexRiscv
