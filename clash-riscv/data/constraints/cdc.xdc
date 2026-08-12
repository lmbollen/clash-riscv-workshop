# Timing exceptions for Workshop.Top.topEntity.
#
# Clash already writes the CLK clock constraint itself, into topEntity.sdc,
# so this file only has to describe what Clash cannot know: the second clock
# arriving on the JTAG port, and which paths carry no timing relationship at
# all. Everything here is board independent -- pin placement (PACKAGE_PIN,
# IOSTANDARD) belongs in a separate board file.

#############################################################################
# JTAG debug port
#############################################################################

# The debug probe brings its own free-running clock, and the VexRiscv debug
# module clocks registers on both edges of it. Clash cannot declare it: TCK
# reaches the design as an ordinary Bit inside JtagIn, not as a Clock port, so
# no create_clock for it ends up in topEntity.sdc.
#
# 41.666 ns is 24 MHz, the default speed of a USB Blaster II. Adjust to match
# your probe -- OpenOCD's `adapter speed` has to stay under whatever is set
# here, or the design is being timed for a clock slower than the real one.
create_clock -name {JTAG_TCK} -period 41.666 [get_ports {JTAG_TCK}]

# Vivado assumes every pair of clocks is related unless told otherwise, so
# without this it would try to meet setup and hold on every path between the
# debug module and the CPU. CLK and JTAG_TCK come from different oscillators
# and have no phase relationship; the debug module synchronises across the
# boundary itself.
set_clock_groups \
  -asynchronous \
  -group [get_clocks -include_generated_clocks {CLK}] \
  -group [get_clocks -include_generated_clocks {JTAG_TCK}]

# TDI to TDO is a shift-register bypass with no relationship to the rest of the
# design.
set_false_path -from [get_ports {JTAG_TDI}] -to [get_ports {JTAG_TDO}]

#############################################################################
# UART
#############################################################################

# UART_RX arrives over a cable with no accompanying clock. The receiver in
# Clash.Cores.Uart puts it through a two-flop synchroniser and then majority
# votes three oversamples of it, so there is no setup/hold relationship worth
# constraining -- only the metastability window, which the synchroniser is
# there to absorb.
set_false_path -from [get_ports {UART_RX}]

# Likewise UART_TX is sampled by whatever is on the other end of the wire, not
# by anything clocked inside this design.
set_false_path -to [get_ports {UART_TX}]
