##----------------------------------------------------------------------------##
#   Synthesis and programming for the OrangeCrab r0.2.1 (ECP5-85F)             #
#                                                                              #
#   Modelled on the Makefile in the clash-starters OrangeCrab template. Run    #
#   everything from inside `nix develop`, which supplies yosys, nextpnr-ecp5,  #
#   ecppack and openFPGALoader.                                                #
#                                                                              #
#     make bitstream   synthesise, place & route, pack   (the default)         #
#     make upload      load the bitstream into FPGA SRAM (lost on power cycle) #
#     make console     watch the SoC's serial output                           #
#     make run         upload, then open the console                           #
##----------------------------------------------------------------------------##

MODULE   = Workshop.Top
TOP      = topEntity
BUILDDIR = _build/fpga
LPF      = clash-riscv/data/constraints/orangecrab.lpf

# Where Clash puts its output, and the ELF whose contents get baked into the
# instruction memory. The firmware has to exist *before* the Clash build, or the
# CPU comes up with empty memories -- see Workshop.Firmware.loadElfMemoriesTH.
HDLDIR   = verilog/$(MODULE).$(TOP)
FIRMWARE = _build/cargo/riscv32imc-unknown-none-elf/release/hello-world

# ECP5-85F in the CSFBGA285 package, as fitted to the OrangeCrab r0.2.1.
#
# The CPU domain closes 48 MHz only marginally, and which seeds manage it is not
# predictable. The critical path runs from the data memory's block RAM, through
# the interconnect, into VexRiscv's decode and register file -- about a third
# logic and two thirds routing, so it is placement rather than logic depth, and
# the placer seed moves the result by more than the shortfall.
#
# Measured across seeds 1-8 with the Ethernet SoC (VexRiscv + serial + encoder +
# the UDP socket and its stack): 50.47, 51.36, 49.78, 47.88, 54.90, 47.74,
# 56.08, 51.52 MHz. Two of eight fail. Seed 7 has the most margin.
#
# Expect to redo this whenever the design changes -- the previous pick, seed 4,
# went from passing to 47.88 MHz on a change that added one 16-bit comparator.
# Sweep before concluding anything is broken:
#
#   for s in $(seq 1 8); do nextpnr-ecp5 --json _build/fpga/topEntity.json \
#     --textcfg /tmp/s$s.config --85k --package CSFBGA285 --lpf $(LPF) \
#     --seed $s 2>&1 | grep "Max frequency.*CLK"; done
PNR_SEED  = 7
PNR_FLAGS = --85k --package CSFBGA285 --lpf $(LPF) --seed $(PNR_SEED)

# Last resort for bring-up: `make bitstream PNR_TIMING=--timing-allow-fail`
# builds a bitstream even when timing fails. The design will probably still run
# at room temperature a percent or two over, but it is not a guarantee -- prefer
# finding a seed that closes.
PNR_TIMING =

# The board has no on-board programmer; an FT232H drives its JTAG. `-c ft232`
# selects that probe. This writes SRAM only, so it does not wear the SPI flash
# and the board reverts to its previous contents on power cycle.
PROG       = openFPGALoader
PROG_FLAGS = -c ft232

# The USB-UART adapter on PMOD 1. Override if it enumerates elsewhere:
#   make console SERIAL=/dev/ttyUSB2
SERIAL = /dev/ttyUSB1
BAUD   = 115200

YOSYS = yosys
PNR   = nextpnr-ecp5
PACK  = ecppack
CARGO = cargo

-include build.cfg.local

##----------------------------------------------------------------------------##
#   Firmware                                                                   #
##----------------------------------------------------------------------------##

# The Rust program the CPU runs. Cargo's target directory and RISC-V target come
# from firmware/.cargo/config.toml, so this only has to pick the profile.
#
# The generated sources under firmware/hal/src/hals/ are left out of the
# prerequisites on purpose: cargo's build.rs rewrites them from the memory map on
# every regeneration, so listing them would make this rule permanently out of
# date and drag the whole bitstream along with it.
FIRMWARE_SRCS = $(shell find firmware \
  \( -name '*.rs' -o -name '*.toml' -o -name '*.lock' \) \
  -not -path 'firmware/hal/src/hals/*')

# The PAC the firmware is generated against comes out of the Clash side: a
# Template Haskell splice in Workshop.MemoryMaps writes memory_maps/Soc.json when
# the library is compiled. So the memory map has to exist before cargo runs.
memory_maps/Soc.json:
	cabal build all

$(FIRMWARE): $(FIRMWARE_SRCS) memory_maps/Soc.json
	cd firmware && $(CARGO) build --release

firmware: $(FIRMWARE)

##----------------------------------------------------------------------------##
#   Build rules                                                                #
##----------------------------------------------------------------------------##

.PHONY: default bitstream synth netlist firmware upload console run \
        loopback clean help

# nextpnr writes its .textcfg before it reports a timing failure, and ecppack is
# happy to pack it. Without this, a failed place & route leaves a stale target
# behind, the next `make bitstream` says there is nothing to do, and `make upload`
# programs the board with a build that does not meet timing -- which then presents
# as a mysterious hardware fault. Let make delete any target whose recipe failed.
.DELETE_ON_ERROR:

default: bitstream

bitstream: $(BUILDDIR)/$(TOP).bit
netlist:   $(BUILDDIR)/$(TOP).config
synth:     $(BUILDDIR)/$(TOP).json

# 1. Clash: Haskell -> Verilog.
#
# Workshop.Top splices the firmware ELF into its block RAMs at compile time (see
# Workshop.Firmware.loadElfMemoriesTH), so the ELF has to exist first. A top entity without
# a CPU would override HDL_DEPS to nothing on the command line; it is a plain variable rather
# than a target-specific one because make expands a rule's prerequisites when it parses the
# rule.
#
# Note that a *new* ELF does not by itself force this rule's output to be regenerated for
# the right reason: the ELF is read by a Template Haskell splice, so if Workshop.Top has not
# otherwise changed, GHC may reuse its object file and the bitstream keeps the old program.
# Delete $(HDLDIR) if you need to be certain.
HDL_DEPS = $(FIRMWARE)

$(HDLDIR)/$(TOP).v: $(HDL_DEPS)
	cabal build all
	cabal run clash-riscv:clash $(MODULE) -- --verilog

# 2. yosys: Verilog -> ECP5 netlist. Every .v Clash emitted is read, since the
#    VexRiscv core and the memories live in their own files.
$(BUILDDIR)/$(TOP).json: $(HDLDIR)/$(TOP).v
	mkdir -p $(BUILDDIR)
	$(YOSYS) -l $(BUILDDIR)/synth.log \
	  -p 'read_verilog $(HDLDIR)/*.v; synth_ecp5 -top $(TOP) -json $@'

# 3. nextpnr: place & route against the pin constraints.
$(BUILDDIR)/$(TOP).config: $(BUILDDIR)/$(TOP).json $(LPF)
	$(PNR) --json $< --textcfg $@ $(PNR_FLAGS) $(PNR_TIMING) \
	  --log $(BUILDDIR)/pnr.log

# 4. ecppack: netlist -> bitstream.
$(BUILDDIR)/$(TOP).bit: $(BUILDDIR)/$(TOP).config
	$(PACK) --compress --freq 38.8 --input $< --bit $@

##----------------------------------------------------------------------------##
#   Board                                                                      #
##----------------------------------------------------------------------------##

upload: $(BUILDDIR)/$(TOP).bit
	$(PROG) $(PROG_FLAGS) $<

# Ctrl-A Ctrl-X quits picocom.
console:
	picocom --baud $(BAUD) --imap lfcrlf $(SERIAL)

run: upload console

# The whole design end to end: build the firmware and the bitstream, program the
# board, and exercise every layer of the Ethernet peripheral from the host.
#
# This is the acceptance test for the SoC. The fabric answers ARP and ICMP by
# itself, so `ping` succeeding proves the stack independently of the CPU; a
# datagram coming back proves the receive ring, the CPU's access to it, the
# transmit buffer and the firmware on top of all of it.
#
# The board's address is set by the firmware, not by this file -- see
# firmware/hello-world/src/main.rs. The host end needs an address on the same
# subnet:  nmcli device modify $(ETH_IFACE) ipv4.addresses 10.0.0.1/24
loopback: $(FIRMWARE) $(BUILDDIR)/$(TOP).bit
	$(MAKE) upload
	@echo "##--------------------------------------------------------------##"
	@echo "  Expect an ARP exchange, a ping reply, and each datagram echoed"
	@echo "  back byte for byte."
	@echo ""
	@echo "  Nothing at all        -> no link; check the Pmod is on PMOD 2 and"
	@echo "                           that $(ETH_IFACE) has an address."
	@echo "  ping works, UDP does  -> the fabric is fine and the CPU is not;"
	@echo "  not                      watch the console for the banner."
	@echo "##--------------------------------------------------------------##"
	# The script waits for the board before it starts: programming resets the
	# PHY, so the link drops and renegotiates, and for a second or two
	# afterwards nothing answers. That is not a failure.
	./scripts/eth-traffic.py

# The USB NIC on the other end of the Ethernet Pmod's cable.
ETH_IFACE = enx9cbf0d001512

clean:
	rm -Rf $(BUILDDIR)

help:
	@echo "make bitstream     synthesise, place & route and pack (default)"
	@echo "make firmware      build the Rust program the CPU runs"
	@echo "make upload        load the bitstream into FPGA SRAM"
	@echo "make console       watch serial output on $(SERIAL) at $(BAUD) baud"
	@echo "make run           upload, then open the console"
	@echo "make loopback      build everything, program the board and exercise"
	@echo "                   the Ethernet peripheral end to end"
	@echo "make clean         remove $(BUILDDIR)"
