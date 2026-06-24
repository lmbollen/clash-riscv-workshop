# clash-riscv-workshop

A hands-on workshop for building a minimal **RISC-V System-on-Chip (SoC)** in
[Clash](https://clash-lang.org) (Haskell-to-hardware) together with the **Rust
firmware** that runs on it. It is small on purpose: the goal is to see every
piece you need to build and program a SoC, and nothing more.

The target you'll build toward: a VexRiscv CPU running a bare-metal Rust program
that prints `Hello world` out a serial peripheral, observed on stdout when you
run the SoC in simulation.

This branch (`master`) is the **starting point**: it gives you the reusable
building blocks and toolchain, and leaves the SoC, its memory map, and the
firmware for you to write. See [What you'll build](#5-what-youll-build) below.

---

## 1. What a SoC is made of

A System-on-Chip is a complete computer on one chip. The minimum you need:

| Component        | Job                                                              | Here                          |
|------------------|------------------------------------------------------------------|-------------------------------|
| **CPU core**     | Fetches and executes instructions.                               | VexRiscv (RV32IMC)            |
| **Memory**       | Holds the program (instructions) and its data.                   | Two block-RAMs                |
| **Interconnect** | A bus + address decoding that lets the CPU reach memory and I/O. | Wishbone + simple interconnect|
| **Peripheral(s)**| Talk to the outside world (serial, GPIO, timers…).               | Stream of (ascii) bytes       |

The CPU is a *bus master*: it issues reads and writes against a flat address
space. The interconnect looks at the address and routes each request to the right
destination, the instruction memory, data memory, or a peripheral.

## 2. How does the CPU know the memory layout?
In this workshop we will use the `clash-protocols-memmap` package. This package offers infrastructure
that enables us to create devices to be connected to the CPU and interconnect infrastructure to make them
all accessable.

When we connect all the components together, we get the memory layout as a byproduct that we can then
store in a JSON file. Then we can use a rust package to take this JSON file and produce rust or C modules
that contain getter and setter functions that we can use to access the peripherals. This way we don't
have to worry about addresses ourselves and the infrastructure takes care of it for us.

Based on these generated modules we can then create Hardware Abstraction Layers (HALs) to create user friendly
interfaces to our peripherals.

## 3. What you need to program it

Building a SoC is hardware *and* software. The tools split along that line:

**Hardware (describe + simulate the chip):**
- **GHC** — write the hardware in Haskell; Clash compiles it to
  Verilog/VHDL and can also *simulate* it as ordinary Haskell. Furthermore due to our use
  of `clash-protocols-memmap` GHC can also generate the memory map.
- A **CPU generator** — the VexRiscv core is generated from SpinalHDL (Scala),
  which is why the dev shell carries a JDK, sbt, Verilator and `make`.

**Software (Embedded code that runs on the CPU):**
- A **Rust cross-compiler** targeting `riscv32imc-unknown-none-elf` (bare metal,
  `#![no_std]`).
- A **peripheral access code generator** so the program can talk to peripherals by name
  instead of magic addresses.
- A **linker script generator** We also use rust tools to generate a linker script based on the
  memory map that contains the addresses and sizes of the memories.

---

## 4. Repository layout

What's provided in this starting point:

```
clash-riscv-workshop/
├── flake.nix              Dev shell: GHC + Clash + Scala + Rust toolchains
├── cabal.project          Haskell packages and their pinned git dependencies
│
├── clash-cpus/            The VexRiscv core (Scala config + Clash wrapper) — provided
│
├── clash-riscv/           The hardware (Clash)
│   └── src/Workshop/
│       ├── Cpu.hs         Processing element: CPU + memories + interconnect — provided
│       ├── Peripheral.hs  The SerialBytes peripheral — provided
│       ├── Memory.hs      Wishbone block-RAM storage — provided
│       ├── Firmware.hs    Loads a compiled ELF into the SoC's memories — provided
│       ├── MemoryMaps.hs  Emits memory_maps/*.json at compile time — provided (you register your SoC)
│       └── Project.hs     A tiny standalone Clash `topEntity` example — provided
│   └── bin/{Clash,Clashi}.hs   Clash compiler / REPL entry points — provided
│
└── firmware/              The software (Rust)
    └── hal/               Device-access crate — its PAC generator (build.rs) is provided;
                           it GENERATES the PAC (register accessors + DeviceInstances) from the memory map
```

You will create, over the course of the workshop:

```
├── clash-riscv/src/Workshop/Soc.hs   Wire the CPU + peripheral into a complete SoC
├── clash-riscv/bin/Sim.hs            Run the firmware on the SoC in simulation
└── firmware/
    ├── hal/                          The HAL layer — ergonomic driver methods added to the generated device types (in the hal crate)
    └── hello-world/                  The application: prints "Hello world"
```

---

## 5. What you'll build

The workshop is split into steps. Each step has a companion branch holding its
finished state, so if you get stuck you can check out the next branch and peek at
the solution:

1. **Define the SoC** — wire `processingElement` (CPU + memories) and the
   `serialBytes` peripheral into a complete SoC in `Workshop.Soc`.
2. **Generate the memory map** — register your SoC in `Workshop.MemoryMaps` so
   the Clash build emits `memory_maps/Soc.json`, the single source of truth that
   ties hardware addresses to software.
3. **Generate the PAC** — build the firmware so the `hal` crate's `build.rs` turns
   that JSON into typed, volatile register accessors (and `DeviceInstances`) under
   `hal/src/hals/`.
4. **Write the HAL** — add ergonomic driver methods (and a `ufmt::uWrite` impl)
   directly onto the generated device types, in the same `firmware/hal` crate.
5. **Write the program** — use the HAL to write the `hello-world` application
   that prints `Hello world`.
6. **Simulate the core** — load the compiled firmware into the SoC and run it in
   pure-Haskell simulation, checking the captured serial output.

---

## 6. Quickstart

Everything happens inside the Nix dev shell, which pins every toolchain:

```sh
nix develop
```

**Build the provided Clash code** and run its tests:

```sh
cabal build all
cabal run test-library
cabal run clash-riscv:doctests
```

**Generate HDL** for the standalone Clash example (`Workshop.Project`):

```sh
nix run        # writes Verilog under ./verilog
```

From here, start with step 1 above. Once you have a SoC and its memory map, the
Clash build (re)writes `memory_maps/Soc.json`; rebuild the Clash side first, then
the firmware, so the PAC and linker script always pick up the current map.
