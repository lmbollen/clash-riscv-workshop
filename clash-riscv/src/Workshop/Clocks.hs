{-# LANGUAGE QuasiQuotes #-}
-- 'createDomain' below generates a warning about orphan instances.
{-# OPTIONS_GHC -Wno-orphans #-}

{- | The board's clock domains, and the PLL that makes one from the other.

The OrangeCrab has a single 48 MHz crystal, chosen because the ECP5 speaks USB.
The Ethernet Pmod needs 50 MHz. Both domains and the PLL between them live here
rather than in "Workshop.Top", because "Workshop.Top" needs the PLL and the PLL
needs a domain to be in -- putting them in the same module as the top entity
makes a cycle.

A 50 MHz clock for the Ethernet Pmod, made from the OrangeCrab's 48 MHz
oscillator by one of the ECP5's PLLs.

The board has a single 48 MHz crystal, chosen because the ECP5 speaks USB. RMII
does not care what your board has: the LAN8720A on the Ethernet Pmod is strapped
@nINTSEL=1@, which means it takes its reference clock from @CLKIN@ and expects
that clock to be 50 MHz. Everything downstream of it -- the 25 MHz internal
divide, the 125 Mbaud line rate, the inter-packet gap -- is derived from that
reference, so \"close to 50\" is not a thing: the RMII specification allows 50 ppm
and the link simply will not come up outside it.

48 MHz is not a multiple of 50 MHz, so the PLL has to do a genuine ratio: 25/24.
The parameters below come from @ecppll@ (Project Trellis) and are exact --

> ecppll -i 48 -o 50 --highres --clkin_name clk48 --clkout0_name clk50 -n ecp5pll

-- giving a 24 MHz phase detector, a 600 MHz VCO and a /50.000/ MHz secondary
output. Regenerate with that command if you ever need a different frequency, but
read the note on @CLKOS_CPHASE@ below before pasting the result in.

Clash ships clock generators for Xilinx, Intel and Gowin but not for Lattice
ECP5, so this is a hand-written black box. There is nothing to simulate: in
Haskell it hands back 'clockGen' and the domain's period is what makes the
simulation run at 50 MHz.
-}
module Workshop.Clocks (Dom48, Dom50, ecp5Pll, ecp5ClockOut) where

import Clash.Prelude

import Clash.Annotations.Primitive (HDL (..), Primitive (InlineYamlPrimitive))
import Data.String.Interpolate (__i)


{- | The OrangeCrab's 48 MHz oscillator, with a synchronous, __active-high__
reset.

This deliberately differs from @Orangecrab.Domain.Dom48@ in the clash-starters
template, which is active-low so that the board's user button can drive it
directly. Active-low is wrong for this design: @clash-vexriscv@'s blackbox wires
the reset straight to the SpinalHDL core's @reset@ port with no polarity
conversion, and that port is active-high. On an active-low domain Clash hands it
the raw active-low signal, so the CPU is released while the rest of the design is
still in reset and then held in reset forever afterwards --

> assign result_1 = (counter == 12'd4095);   // power-on window elapsed
> assign ... = result_1 & ...;               // -> VexRiscv .reset, i.e. backwards

-- which is silent and looks exactly like a dead SoC. Nothing catches it in
simulation either, because there Clash drives the Verilator model through an
interface that does respect the domain's polarity.

Since 'powerOnReset' makes the button unnecessary, active-high costs nothing.
-}
createDomain
  vSystem
    { vName = "Dom48"
    , vPeriod = hzToPeriod 48_000_000
    , vResetKind = Synchronous
    , vResetPolarity = ActiveHigh
    }

{- | The PLL output domain: 50 MHz, synchronous active-high reset, matching
'Workshop.Top.Dom48' in everything but the period.
-}
createDomain
  vSystem
    { vName = "Dom50"
    , vPeriod = hzToPeriod 50_000_000
    , vResetKind = Synchronous
    , vResetPolarity = ActiveHigh
    }

{- | 48 MHz in, 50 MHz out.

The @LOCK@ output is deliberately not returned. Returning a clock /and/ a signal
from one black box means describing a product type to the HDL backend, which is
why Clash's own clock generators need a template function in @clash-lib@ rather
than an inline primitive. Nothing here needs it: the design holds itself in reset
for 'Workshop.Top.ResetCycles' (20 ms at 50 MHz) after configuration, and the PLL
locks in microseconds, so by the time any logic runs the clock is long since
good.
-}
ecp5Pll :: Clock Dom48 -> Clock Dom50
ecp5Pll !_ = clockGen
{-# OPAQUE ecp5Pll #-}
{-# ANN ecp5Pll (InlineYamlPrimitive [Verilog] [__i|
  BlackBox:
    name: Workshop.Clocks.ecp5Pll
    kind: Declaration
    template: |-
      // ecp5Pll begin
      wire ~GENSYM[pll_clkos][0];
      wire ~GENSYM[pll_clkfb][1];
      wire ~GENSYM[pll_lock][2];
      (* FREQUENCY_PIN_CLKI="48" *)
      (* FREQUENCY_PIN_CLKOS="50" *)
      (* ICP_CURRENT="12" *) (* LPF_RESISTOR="8" *)
      (* MFG_ENABLE_FILTEROPAMP="1" *) (* MFG_GMCREF_SEL="2" *)
      EHXPLLL \#(
          .PLLRST_ENA("DISABLED"),
          .INTFB_WAKE("DISABLED"),
          .STDBY_ENABLE("DISABLED"),
          .DPHASE_SOURCE("DISABLED"),
          .OUTDIVIDER_MUXA("DIVA"),
          .OUTDIVIDER_MUXB("DIVB"),
          .OUTDIVIDER_MUXC("DIVC"),
          .OUTDIVIDER_MUXD("DIVD"),
          .CLKI_DIV(2),
          .CLKOP_ENABLE("ENABLED"),
          .CLKOP_DIV(25),
          .CLKOP_CPHASE(9),
          .CLKOP_FPHASE(0),
          .CLKOS_ENABLE("ENABLED"),
          .CLKOS_DIV(12),
          // ecppll --highres emits garbage here (CPHASE 678424132, FPHASE 31438:
          // an uninitialised float printed as an integer). Zero is correct and it
          // does not matter anyway -- the output phase of a free-running reference
          // clock is unobservable, and the same edge clocks both the pin and the
          // logic that samples the PHY, so any phase shift is common-mode.
          .CLKOS_CPHASE(0),
          .CLKOS_FPHASE(0),
          .FEEDBK_PATH("CLKOP"),
          .CLKFB_DIV(1)
        ) ~GENSYM[pll_inst][3] (
          .RST(1'b0),
          .STDBY(1'b0),
          .CLKI(~ARG[0]),
          .CLKOP(~SYM[1]),
          .CLKOS(~SYM[0]),
          .CLKFB(~SYM[1]),
          .CLKINTFB(),
          .PHASESEL0(1'b0),
          .PHASESEL1(1'b0),
          .PHASEDIR(1'b1),
          .PHASESTEP(1'b1),
          .PHASELOADREG(1'b1),
          .PLLWAKESYNC(1'b0),
          .ENCLKOP(1'b0),
          .LOCK(~SYM[2])
        );
      assign ~RESULT = ~SYM[0];
      // ecp5Pll end
  |]) #-}

{- | Forward a clock to an output pin.

Sending a clock off-chip is not the same as sending a signal off-chip, and
wiring a clock net straight to a port only looks like it works. The clock lives
on the ECP5's global network, which is built to reach flip-flop clock inputs --
not IO output drivers. Routing it out that way leaves the tools to get it there
through general interconnect, and what arrives at the pin is late, skewed
relative to the flops it is supposed to be aligned with, and may not arrive at
all.

The intended path is an output DDR register. 'ODDRX1F' clocked by the very clock
being forwarded, with its two data inputs tied to 1 and 0, emits one every half
period: a clean copy of the clock, driven by the IO cell's own output register,
with the same launch point as every other output in the domain.

For a PHY that is being handed its only reference clock, this is the difference
between a link and a dead board.
-}
ecp5ClockOut :: Clock Dom50 -> Signal Dom50 Bit
ecp5ClockOut !_ = pure 0
{-# OPAQUE ecp5ClockOut #-}
{-# ANN ecp5ClockOut (InlineYamlPrimitive [Verilog] [__i|
  BlackBox:
    name: Workshop.Clocks.ecp5ClockOut
    kind: Declaration
    template: |-
      // ecp5ClockOut begin
      ODDRX1F ~GENSYM[oddr_inst][0] (
          .SCLK(~ARG[0]),
          .RST(1'b0),
          .D0(1'b1),
          .D1(1'b0),
          .Q(~RESULT)
        );
      // ecp5ClockOut end
  |]) #-}
