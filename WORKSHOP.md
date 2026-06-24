# Workshop: build a RISC-V SoC that says hello

Welcome. On the bench in front of you is a pile of parts: a RISC-V CPU, two
blocks of memory, a serial port, and a bus to connect them. None of it is wired
up. By the end of this workshop you'll have assembled them into a working
**System-on-Chip**, written a tiny Rust program for it, and — without any FPGA —
watched the chip boot and print **`Hello world`** in a pure-Haskell simulation.

You'll build it in six steps, alternating between the two halves of the repo:

| # | Step | Side | You write | Companion branch |
|---|------|------|-----------|------------------|
| 1 | Give the machine a shape | Clash | `Workshop.Soc` | `1-define-soc` |
| 2 | Draw the map | Clash | one list entry | `2-generate-memory-map` |
| 3 | Teach software the addresses | Rust | *(nothing — generated)* | `3-generate-pac` |
| 4 | Make it ergonomic | Rust | `firmware/hal` | `4-write-hal` |
| 5 | Say something | Rust | `firmware/hello-world` | `5-write-program` |
| 6 | Listen in | Clash | `clash-riscv/bin/Sim.hs` | `6-simulate-core` |

This guide points you in the right direction for each step — what to build, which
provided pieces to use, and which cheatsheet explains the concept — but it
deliberately does **not** hand you the code. Each step has a **companion branch**
with the finished state; reach for it when you're stuck:

```sh
git show 1-define-soc:clash-riscv/src/Workshop/Soc.hs   # peek at one file
git switch 1-define-soc                                 # or check out the whole solution
```

---

## Before you start

Everything runs inside the pinned toolchain shell:

```sh
nix develop
```

**Keep the four cheatsheets open** — each step points you at the relevant one:

- [docs/circuit-notation-cheatsheet.md](docs/circuit-notation-cheatsheet.md) — the `circuit … -<` arrow DSL you wire the SoC with.
- [docs/clash-protocols-cheatsheet.md](docs/clash-protocols-cheatsheet.md) — `Circuit`, `Df`, `ToConstBwd`, `idleSource`, simulation.
- [docs/clash-protocols-memmap-cheatsheet.md](docs/clash-protocols-memmap-cheatsheet.md) — memory maps, and how a design emits its `memory_maps/*.json`.
- [docs/code-generator-cheatsheet.md](docs/code-generator-cheatsheet.md) — the Rust PAC generated from that JSON, and the HAL on top.

### The parts already on the bench (provided)

You do **not** write these — you wire them together:

| Module | What it gives you |
|--------|-------------------|
| [Workshop.Cpu](clash-riscv/src/Workshop/Cpu.hs) | `processingElement` (VexRiscv core + instruction/data memory + interconnect) and its `PeConfig` (`depthI`, `depthD`, `initI`, `initD`). |
| [Workshop.Peripheral](clash-riscv/src/Workshop/Peripheral.hs) | `serialBytes` — the one external peripheral: a byte-oriented serial port with a single `byte` register. |
| [Workshop.Firmware](clash-riscv/src/Workshop/Firmware.hs) | `loadElfMemories` — reads a compiled RISC-V ELF into instruction/data memory images (used in step 6). |
| [Workshop.MemoryMaps](clash-riscv/src/Workshop/MemoryMaps.hs) | compile-time machinery that emits `memory_maps/*.json` (you register your SoC in step 2). |
| [Workshop.Utils](clash-riscv/src/Workshop/Utils.hs) | `findParentContaining` — locate the repo root at runtime. |
| [Workshop.Memory](clash-riscv/src/Workshop/Memory.hs), [DoubleBufferedRam](clash-riscv/src/DoubleBufferedRam.hs), [Wishbone](clash-riscv/src/Wishbone.hs), [SharedTypes](clash-riscv/src/SharedTypes.hs) | the block-RAM storage, bus fabric and shared types that `Workshop.Cpu` is built from. |

The Rust side ([firmware/](firmware/)) is a Cargo workspace; on `master` it holds
only the `hal` crate with its PAC generator ([firmware/hal/build.rs](firmware/hal/build.rs)).
That one crate holds both layers of device access: the **PAC** it generates from the
memory map, and the **HAL** drivers you add on top (step 4). The program you write
in step 5 is a separate crate that just depends on it.

### One rule about ordering

The Clash build is the source of truth: it writes `memory_maps/Soc.json`, and the
Rust generators read it. **Always (re)build the Clash side before the firmware**
so the PAC and linker script track the current hardware.

---

## Step 1 — Give the machine a shape (define the SoC)

> The CPU can fetch and execute, the serial port can shift out bytes — but the
> wires between them don't exist yet. Your first job is to draw them.

**Goal:** create `clash-riscv/src/Workshop/Soc.hs` exporting a circuit `soc` and a
value `memoryMap`, and add `Workshop.Soc` to the `exposed-modules` in
[clash-riscv/clash-riscv.cabal](clash-riscv/clash-riscv.cabal).

Your `soc` is a `Circuit`. Steps 2 and 6 tell you the shape it must have: on the
left it accepts the design's **memory-map channel** (a `ToConstBwd Mm` port) and a
**serial-input** byte stream; on the right it produces a **serial-output** byte
stream (`Df System (BitVector 8)`). Work out that signature, then wire the body
from the provided parts:

- **The processing element.** Use `processingElement` from
  [Workshop.Cpu](clash-riscv/src/Workshop/Cpu.hs), configured with a `PeConfig`.
  Read that module for its fields: `depthI`/`depthD` size the instruction/data
  memories, and `initI`/`initD` seed them — leave the memories empty for now
  (step 6 is where firmware gets loaded). The type parameter counts the busses:
  the two internal memories always take one each, plus one per external
  peripheral. You have a single serial peripheral, so size it accordingly.
- **The peripheral.** `serialBytes` from
  [Workshop.Peripheral](clash-riscv/src/Workshop/Peripheral.hs) is the device to
  hang off the external bus; it consumes the serial-in stream together with that
  bus and yields the serial-out stream.
- **JTAG.** `processingElement` exposes a JTAG debug port, but this SoC has no
  debugger. A protocol port can't be left dangling — every input must be driven —
  so connect it to a source that never produces anything: `idleSource`
  (`Protocols.Idle`). See the
  [clash-protocols cheatsheet §6](docs/clash-protocols-cheatsheet.md#6-idle--escaping-to-raw-signals).
- **Byte order.** The register infrastructure needs a `ByteOrder` in scope; this
  SoC is little-endian. The *why* is in the
  [clash-protocols-memmap cheatsheet §5](docs/clash-protocols-memmap-cheatsheet.md#5-register-values-bitpackc--byte-order).

**How to connect them** is exactly what the circuit-notation DSL is for. Enable it
with the plugin pragma `{-# OPTIONS_GHC -fplugin=Protocols.Plugin #-}`, then reach
for the [circuit-notation cheatsheet](docs/circuit-notation-cheatsheet.md): it
shows how the lambda binds your inputs (§3), how `-<` connects a component (§4),
how the final statement produces the output (§5), and — you'll need this —
how to pattern-match the **vector of external busses** `processingElement` returns
using list syntax (§6).

Finally, expose the design's memory map as the top-level value `memoryMap` so
step 2 can consume it. `getMMAny` reads the map out of a finished circuit — see the
[clash-protocols-memmap cheatsheet §4](docs/clash-protocols-memmap-cheatsheet.md#4-composing--exposing-the-map).

**Verify:** `cabal build all` compiles cleanly. *(Peek: `1-define-soc`.)*

---

## Step 2 — Draw the map (generate the memory map)

> The chip now has a shape, and every device sits at some address. Let's write
> that map down where the software can find it.

**Goal:** register your SoC in
[clash-riscv/src/Workshop/MemoryMaps.hs](clash-riscv/src/Workshop/MemoryMaps.hs).
It already contains a compile-time splice that turns a list of named maps into JSON
files — you just add yours to the list:

```haskell
import qualified Workshop.Soc as Soc
...
let memoryMaps =
      [ ("Soc", Soc.memoryMap)   -- <- add this
      ]
```

**Verify:** `cabal build all`. The splice writes `memory_maps/Soc.json`. Open it:
you'll find the three devices (`InstructionMemory`, `DataMemory`, `SerialBytes`)
and their addresses — `SerialBytes` lands at `0xC000_0000`. That file is a **build
artifact**, never hand-edited.

This is exactly the "writing the map to JSON" flow in the
[clash-protocols-memmap cheatsheet §7](docs/clash-protocols-memmap-cheatsheet.md#7-writing-the-map-to-json);
§6 there explains what the JSON contains. *(Peek: `2-generate-memory-map`.)*

---

## Step 3 — Teach software the addresses (generate the PAC)

> The hardware knows where everything is. Now the software needs to. This step
> writes *itself*.

**Goal:** generate the **PAC** (Peripheral Access Code) — the Rust structs with
typed register accessors — from the memory map. There is **no code to write**: the
`hal` crate's generator [firmware/hal/build.rs](firmware/hal/build.rs) reads
`memory_maps/Soc.json` and emits the modules.

```sh
cd firmware
cargo build
```

Then open the generated (git-ignored) `firmware/hal/src/hals/soc/serial_bytes.rs`
and read the
[code-generator cheatsheet §1–§2](docs/code-generator-cheatsheet.md#2-build-the-pac--the-generated-module)
alongside it, so you understand what you're looking at: a base-pointer struct with
volatile accessors, a getter/setter per register gated by its access mode. Notice
the sibling `firmware/hal/src/hals/soc/instances.rs`: a `DeviceInstances` struct
that constructs every peripheral at its address
([cheatsheet §4](docs/code-generator-cheatsheet.md#4-deviceinstances)) — it's
generated here in the library, so it already exists before you write any program.
You never edit these files — you regenerate them. *(Peek: `3-generate-pac`.)*

---

## Step 4 — Make it ergonomic (write the HAL)

> The raw PAC is precise but clunky to call. Give the device some friendly methods.

**Why `ufmt`?** You want to print text like `"Hello world"` from a `#![no_std]`
program. `core::fmt` (the machinery behind `write!`/`println!`) is heavy for a tiny
CPU, so we use [`ufmt`](https://docs.rs/ufmt), a lightweight formatting crate. Its
`uwrite!`/`uwriteln!` macros work with any type that implements `ufmt::uWrite` — so
if you implement that trait for your serial port, you can print to it directly.

**Goal:** add the **HAL** layer to the `hal` crate — ergonomic driver methods on
top of the generated PAC. The crate already exists (it's where step 3's PAC was
generated); add `ufmt` to its dependencies. Because the PAC is generated *in this
same crate*, the generated device types are **local**, so you add methods and trait
impls straight onto them — no wrapper. Write:

1. An `impl SerialBytes` block (on the generated `hals::soc::SerialBytes`) with a
   method that sends a single `u8`. Sending a byte means turning the `u8` into the
   register's value type and calling the generated setter — see how to construct
   that value in the
   [code-generator cheatsheet §3](docs/code-generator-cheatsheet.md#3-rust-types-conform-to-the-haskell-types),
   and the add-methods-directly pattern in
   [§8](docs/code-generator-cheatsheet.md#8-use-the-devices-from-a-program).
2. **An `ufmt::uWrite` impl for `SerialBytes`.** Its `write_str` should push every
   byte of the incoming `&str` out through your send-a-byte method. That single
   `impl` is what unlocks `uwriteln!(…)` in step 5. (Sending never fails here, so
   the associated `Error` type can be `core::convert::Infallible`.)

Nothing here constructs a device or names an address: the methods live on the
generated type, and the `DeviceInstances` from step 3 is what a program will use to
get a `SerialBytes` to call them on (step 5).

**Verify:** `cargo build`. *(Peek: `4-write-hal`.)*

---

## Step 5 — Say something (write the program)

> Time to give the CPU something to do: greet the world.

**Goal:** add a `hello-world` binary crate (a workspace member). It leans on a few
packages — know what each is for:

- **`riscv-rt`** — the bare-metal RISC-V runtime. It provides `_start`, sets up the
  stack and zeroes `.bss`, and gives you the `#[entry]` attribute to mark your
  `main`. **Pin `riscv-rt = "0.11.0"`**: its `link.x` region scheme and `#[entry]`
  API differ across major versions, and the generated `memory.x` targets the 0.11
  layout — a newer major fails with confusing link/entry errors.
- **`ufmt`** — the formatting macros (`uwriteln!`) your HAL supports (step 4).
- **`hal`** — your device-access crate: the generated PAC plus the drivers you
  wrote in step 4.
- **`memorymap-compiler`** (a *build*-dependency) — provides `memory_x_from_memmap`,
  which turns the memory map into a linker script.

What to do:

1. Write a `#![no_std]` / `#![no_main]` program with a `#[panic_handler]` and an
   `#[entry] fn main() -> !`. In `main`, get the peripherals from
   `hal::hals::soc::DeviceInstances::new()` — it constructs each device at its
   memory-map address, so there are **no literal addresses in your program** — then
   print a greeting to `devices.serial_bytes` with `uwriteln!` (the `uWrite` impl
   you added in step 4 is right on that device) and loop forever. Getting the
   devices from `DeviceInstances` and driving them is the
   [code-generator cheatsheet §8](docs/code-generator-cheatsheet.md#8-use-the-devices-from-a-program).
2. Add a `build.rs` that generates the linker script from the memory map, so
   `.text`/`.data` land in the instruction/data memories. The helper
   `memory_x_from_memmap(&path, "DataMemory", "InstructionMemory")` takes the data-
   and instruction-memory **device names** (as they appear in `Soc.json`) and
   *returns* the `memory.x` bytes — you then write them to `OUT_DIR/memory.x` and
   emit the `cargo:rustc-link-search`, `-Tmemory.x`, and `-Tlink.x` (riscv-rt's)
   directives yourself. (Or let `memorymap_compiler::build_utils::standard_memmap_build("Soc.json", "DataMemory", "InstructionMemory")` do all of it in one call.)

**Verify:** build the ELF — the simulator will look for the **release** build:

```sh
cargo build --release
```

The binary lands at `_build/cargo/riscv32imc-unknown-none-elf/release/hello-world`.
*(Peek: `5-write-program`.)*

---

## Step 6 — Listen in (load the binary into Haskell and simulate)

> No FPGA, no serial cable — yet you can still hear the chip talk. Clash simulates
> the whole SoC as an ordinary Haskell program: you load the compiled ELF into its
> memories, run it for a while, and read back whatever bytes it pushed out the
> serial port.

**Goal:** add `clash-riscv/bin/Sim.hs` and an `executable` stanza for it. This is
the one step where seeing the machinery in full helps, so here's how it fits
together.

### 6a. A device-under-test with no host input

`Workshop.Soc.soc` exposed a serial *input* for a host to feed. In simulation
there is no host, and the memories must start with the firmware. So write a small
variant `dut` that (a) takes the `PeConfig` as a parameter (so we can hand it
firmware-loaded memories) and (b) ties the serial input to `idleSource`:

```haskell
dut :: PeConfig 3 -> Circuit (ToConstBwd Mm.Mm, ()) (Df System (BitVector 8))
dut peConfig =
  let ?byteOrder = LittleEndian
   in withClockResetEnable clockGen (resetGenN d2) enableGen
        $ circuit $ \(mm, _noInput) -> do
          jtag        <- idleSource -< ()
          serialIn    <- idleSource -< ()                  -- nothing coming in
          [serialBus] <- processingElement NoDumpVcd peConfig -< (mm, jtag)
          serialOut   <- serialBytes -< (serialIn, serialBus)
          idC -< serialOut
```

### 6b. Load the compiled binary into the memories

This is the key idea. [Workshop.Firmware](clash-riscv/src/Workshop/Firmware.hs)
provides:

```haskell
loadElfMemories ::
  (KnownNat depthI, KnownNat depthD) =>
  FilePath -> IO (ContentType depthI (Bytes 4), ContentType depthD (Bytes 4))
```

It reads the RISC-V ELF, sends the executable segments to an **instruction**-memory
image and the rest to a **data**-memory image (each byte keyed by the absolute
address the linker assigned in step 5), packs them into little-endian 32-bit words
and pads to the depth. Those two images are exactly the `initI` / `initD` fields of
`PeConfig` — so loading firmware is just building a `PeConfig` with `Just` images
instead of `Nothing`:

```haskell
main :: IO ()
main = do
  root <- findParentContaining "cabal.project"                 -- Workshop.Utils
  let elfPath = root </> "_build" </> "cargo"
              </> "riscv32imc-unknown-none-elf" </> "release" </> "hello-world"
  (iMem, dMem) <- loadElfMemories @1024 @1024 elfPath          -- <- load the binary
  let peConfig  = PeConfig (SNat @1024) (SNat @1024) (Just iMem) (Just dMem)
      simConfig = def{timeoutAfter = 1_000_000}                -- run up to 1e6 cycles
      output    = catMaybes (sampleC simConfig (Mm.unMemmap (dut peConfig)))
      captured  = fmap toChar output
  putStr captured
 where
  toChar :: BitVector 8 -> Char
  toChar b = chr (fromIntegral (unpack b :: Unsigned 8))
```

What the last few lines do:

- `Mm.unMemmap` drops the `ToConstBwd Mm` side-channel, leaving a plain
  `Circuit () (Df System (BitVector 8))` that can be driven.
- `sampleC` (from `Protocols.Experimental.Simulate`, see the
  [clash-protocols cheatsheet §7](docs/clash-protocols-cheatsheet.md#7-simulation--testing))
  runs the circuit and returns one `Maybe (BitVector 8)` per cycle; `catMaybes`
  keeps the cycles that actually transferred a byte.
- Each byte is decoded to a `Char` and printed. Because the firmware called
  `uwriteln!(serial, "Hello world")`, that's what appears.

### 6c. Register and run

Add an `executable` stanza to [clash-riscv/clash-riscv.cabal](clash-riscv/clash-riscv.cabal):

```
executable sim
  import: common-options
  default-language: Haskell2010
  hs-source-dirs: bin
  main-is: Sim.hs
  ghc-options: -threaded
  build-depends:
    base, clash-riscv, clash-prelude, clash-bitpackc, clash-protocols,
    clash-protocols-memmap, clash-vexriscv, filepath
```

Then run the whole pipeline, in order:

```sh
cabal build all                        # (re)emit memory_maps/Soc.json
cd firmware && cargo build --release   # build the ELF (+ regenerate PAC & linker script)
cd ..
cabal run sim                          # load the ELF into the SoC and simulate
```

You should see:

```
Hello world
```

That is your CPU, running your Rust program, on your SoC — every wire simulated in
Haskell. *(Peek: `6-simulate-core`.)*

---

## What you built

```
   Step 1        Step 2            Step 3      Step 4     Step 5          Step 6
 Workshop.Soc → memory_maps/  →  PAC (Rust)  →  HAL   → hello-world  →  Sim.hs
 (wire the SoC)   Soc.json      (generated)   (uWrite)  (Hello world)  (run it)
      │              │              │            │           │             │
      └── hardware ──┴── the map ───┴──────── software ──────┘         simulation
```

- The **memory map** is the contract between hardware and software: one JSON file,
  generated from the Clash design, that drives both the Rust register accessors and
  the linker script.
- Change the hardware → rebuild the Clash side → the map changes → the PAC and
  linker script regenerate → the compiler points you at anything that moved.

### Where to go next

- Add a second peripheral (e.g. a GPIO or a counter) to `Workshop.Soc`, register it,
  rebuild, and drive it from the firmware — the memory map and PAC follow
  automatically.
- If a peripheral is instantiated at several widths, the code generator makes a
  distinct type per instance; see the trait + macro pattern in the
  [code-generator cheatsheet §6](docs/code-generator-cheatsheet.md#6-traits--macros--one-hal-for-many-instances).
- Turn `Sim.hs` into a test by asserting the captured string equals `"Hello world\n"`.
</content>
