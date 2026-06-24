# Code generator (PAC + HAL) cheatsheet

A quick reference for the **firmware side**: how the memory-map JSON becomes Rust
**PAC** (Peripheral Access Code) you can call, and how you build an ergonomic
**HAL** (Hardware Abstraction Layer) on top of it.

> **See also:** [clash-protocols-memmap-cheatsheet.md](clash-protocols-memmap-cheatsheet.md)
> (how the memory map is described in Clash and emitted as JSON),
> [clash-protocols-cheatsheet.md](clash-protocols-cheatsheet.md), and
> [circuit-notation-cheatsheet.md](circuit-notation-cheatsheet.md).
>
> The generator crates (`memorymap-compiler`, `memorymap-compiler-rust`) and the
> runtime value types (`clash-bindings`) live in
> [clash-protocols-memmap](https://github.com/QBayLogic/clash-protocols-memmap).

> Snippets marked `// @generated` are **real output** from the code generator, run
> on small example memory maps (a parametric `SimpleReg` at widths 8 and 16, and a
> `Gpio` with read-only/write-only registers); §4 and §8 use the workshop's own
> `SerialBytes`/`Soc.json`. Snippets for the HAL / interface trait / macro are
> hand-written patterns you'd add yourself.

---

## Overview

```
memory_maps/Soc.json  ──(code generator, in build.rs)──▶  PAC  ──(your HAL, same crate)──▶  application
```

- The **PAC** (Peripheral Access Code) is generated Rust — the `hals` module: one
  module per device with typed, volatile register accessors, plus a
  `DeviceInstances` aggregate (§4). You never edit it — you regenerate it.
- The **HAL** (Hardware Abstraction Layer) is hand-written Rust: ergonomic driver
  methods added **directly to the generated device types**. It lives in the **same
  crate** as the PAC, so those types are local — the HAL gives them inherent methods
  and trait impls (like `ufmt::uWrite`) with no wrapper (§8).
- Both layers ship in **one library crate** (call it `hal`). The PAC is generated
  in that library — independently of any program — so you can build and inspect the
  generated code (and `DeviceInstances`) before writing an application. A program
  then depends on the crate, gets its peripherals from `DeviceInstances`, and drives
  them through the HAL methods (§8).
- Register values are expressed in **`clash-bindings`** types (`BitVector`,
  `Unsigned`, …) whose byte layout matches the Clash side exactly.

---

## 1. Start: the memory-map file

The generator's input is a `memory_maps/<Target>.json` (produced by the Clash
build — see the [memmap cheatsheet](clash-protocols-memmap-cheatsheet.md#7-writing-the-map-to-json)).
It lists every **device**, its **registers**, each register's **address**,
**access mode** (read-only / write-only / read-write) and **type**. One target =
one memory map = one top-level SoC.

---

## 2. Build the PAC → the generated module

For each device the generator emits a struct that is just a **base pointer**
(`*mut u8`), plus one accessor per register. A read-write register storing an
`Unsigned 8` becomes:

```rust
// @generated
pub struct SimpleReg8(pub *mut u8);
impl SimpleReg8 {
    pub const VALUE_WIDTH: usize = 8;
    pub const unsafe fn new(addr: *mut u8) -> Self {
        Self(addr)
    }
    #[doc = "The stored value"]
    pub fn value(&self) -> Unsigned<8, u8> {
        unsafe { self.0.add(0usize).cast::<Unsigned<8, u8>>().read_volatile() }
    }
    #[doc = "The stored value"]
    pub fn set_value(&self, val: Unsigned<8, u8>) {
        unsafe { self.0.add(0usize).cast::<Unsigned<8, u8>>().write_volatile(val) }
    }
}
```

Note the shape you'll rely on later:

- the struct name is the **device** name (`value`/`set_value` are the **register**
  name and `set_` + register name); the width const is `<REG>_WIDTH`;
- every access is a `read_volatile`/`write_volatile` at `base + offset` (the
  register address, `0usize` here) inside `unsafe`, so the compiler can't reorder
  or elide the memory-mapped I/O;
- the register's description becomes a `#[doc]` on the accessor.

**Access mode decides which accessor exists** — a *getter* only for readable
registers, a *setter* only for writable ones. A `Gpio` device with a read-only
`in_pins` and a write-only `out_pins` generates no `set_in_pins` and no `out_pins`:

```rust
// @generated (example device)
pub struct Gpio(pub *mut u8);
impl Gpio {
    pub const IN_PINS_WIDTH: usize = 8;
    pub const OUT_PINS_WIDTH: usize = 8;
    pub const unsafe fn new(addr: *mut u8) -> Self {
        Self(addr)
    }
    #[doc = "Read-only input pins"]
    pub fn in_pins(&self) -> BitVector<8, 1> {           // read-only  → getter only
        unsafe { self.0.add(0usize).cast::<BitVector<8, 1>>().read_volatile() }
    }
    #[doc = "Write-only output pins"]
    pub fn set_out_pins(&self, val: BitVector<8, 1>) {   // write-only → setter only
        unsafe { self.0.add(4usize).cast::<BitVector<8, 1>>().write_volatile(val) }
    }
}
```

A *vector* register additionally gets a checked `reg(i) -> Option<T>`, an
`unsafe reg_unchecked(i)`, and a `reg_volatile_iter()`. Modules are laid out one
directory per target, one file per device (`hals/<target>/<device>.rs`).

---

## 3. Rust types conform to the Haskell types

A register's value type is the Rust mirror of the Clash register type. Because
both sides use the same C-ABI byte layout under the same
[byte order](clash-protocols-memmap-cheatsheet.md#5-register-values-bitpackc--byte-order),
a `read_volatile`/`write_volatile` on the Rust side sees exactly the bytes the
Clash register produced or expects.

| Haskell (`BitPackC`) | Generated Rust (`clash-bindings`) |
|---|---|
| `Bool` | `bool` |
| `Unsigned n` | `Unsigned<n, uNN>`  (e.g. `Unsigned<8, u8>`, `Unsigned<16, u16>`) |
| `Signed n` | `Signed<n, iNN>` |
| `Index n` | `Index<n, uNN>` |
| `BitVector n` | `BitVector<n, N>`  where `N = ⌈n/8⌉` |
| `Bytes n` / masks | `Mask<n, N>` |
| `Float` / `Double` | `f32` / `f64` |
| `Vec n a` | `[a; n]` |
| `(a, b, …)` | `(a, b, …)` |
| record (with a type description) | `#[repr(C)] struct { … }` |
| sum type | `#[repr(uN)]` / `#[repr(C, uN)]` enum |

The backing runtime types are thin, C-compatible wrappers — a bit-vector is a
byte array; an unsigned is a single integer:

```rust
#[repr(transparent)]
pub struct BitVector<const M: usize, const N: usize>(/* [u8; N] */);   // M bits, N bytes
#[repr(transparent)]
pub struct Unsigned<const N: u8, T>(/* T */);                          // N bits, backed by uNN
```

Constructing a value is **bounds-checked** and returns an `Option`:

```rust
let b = BitVector::<8, 1>::new([0x41]).unwrap();   // [u8; N], LSB first
```

So the same value type on both sides means the same bytes at the same addresses.

---

## 4. `DeviceInstances`

The generator emits a **`DeviceInstances`** struct for the memory map: one field
per peripheral, each already constructed at its fixed absolute address (read from
the memory-map tree). It is the entry point that hands you every device,
correctly located:

```rust
// @generated  (from the workshop's Soc.json)
pub struct DeviceInstances {
    pub serial_bytes: SerialBytes,          // field = snake_case of the instance
}
impl DeviceInstances {
    pub const unsafe fn new() -> Self {
        DeviceInstances {
            serial_bytes: unsafe { SerialBytes::new(0xC000_0000 as *mut u8) },
        }
    }
}
```

`DeviceInstances` is part of the generated PAC, so it exists (and can be inspected)
as soon as the library builds — no program required. You never write a raw address
in the application: the memory map assigned them and `DeviceInstances::new()` baked
them in. A program gets each peripheral from it and drives it through the HAL
methods (§8). Devices tagged `no-generate` (the CPU-internal instruction/data
memories) are skipped, so they don't appear here.

---

## 5. One device instance per monomorphic instantiation

When the *same* parametric component is instantiated more than once with
**different type parameters** — e.g. a `SimpleReg` storing `Unsigned n`, used at
`n = 8` and `n = 16` — each instantiation becomes a **separate, unrelated Rust
type**, differentiated by its width. The register value types differ too
(`Unsigned<8, u8>` vs `Unsigned<16, u16>`):

```rust
// @generated
pub struct SimpleReg8(pub *mut u8);
impl SimpleReg8 {
    pub const VALUE_WIDTH: usize = 8;
    pub const unsafe fn new(addr: *mut u8) -> Self { Self(addr) }
    pub fn value(&self) -> Unsigned<8, u8> { /* read_volatile */ }
    pub fn set_value(&self, val: Unsigned<8, u8>) { /* write_volatile */ }
}

// @generated
pub struct SimpleReg16(pub *mut u8);
impl SimpleReg16 {
    pub const VALUE_WIDTH: usize = 16;
    pub const unsafe fn new(addr: *mut u8) -> Self { Self(addr) }
    pub fn value(&self) -> Unsigned<16, u16> { /* read_volatile */ }
    pub fn set_value(&self, val: Unsigned<16, u16>) { /* write_volatile */ }
}
```

Rust's generics/const-generics can't express "the same type at every size" the
way the hardware parameter does, so each monomorphization is its own concrete
struct with only its own inherent methods — there is no shared type relating
`SimpleReg8` and `SimpleReg16`, and each gets its own `DeviceInstances` field.

The width shows up in the **type variable** of the value type (`Unsigned<8, …>`).
It also appears in any **named** parametric type: a Haskell register type like
`data Reading (n :: Nat) = Reading (Unsigned n)`, used at 8 and 16, generates two
distinct types whose monomorphized type variable is appended to the name with an
underscore:

```rust
// @generated  — the type argument (the Nat) is postfixed after "_"
#[allow(non_camel_case_types)]
#[repr(C)]
pub struct Reading_8(pub Unsigned<8, u8>);
#[allow(non_camel_case_types)]
#[repr(C)]
pub struct Reading_16(pub Unsigned<16, u16>);
```

---

## 6. Traits + macros → one HAL for many instances

Because §5 gives you N unrelated types (each with only its own inherent methods),
a single driver can't cover them all directly. The pattern is:

1. an **interface trait** whose members mirror the generated PAC — same method and
   const names — with the per-instance value as an associated type;
2. a `macro_rules!` that, for each generated type, `impl`s the interface by
   forwarding to the inherent generated methods of the same name;
3. the HAL written **once** against the trait.

```rust
// 1. interface trait — same names as the generated PAC (`value`, `set_value`,
//    `VALUE_WIDTH`); the value type differs per instance, so it's associated.
pub trait SimpleRegInterface {
    const VALUE_WIDTH: usize;
    type Value;
    fn value(&self) -> Self::Value;
    fn set_value(&self, val: Self::Value);
}

// 2. macro: impl the interface for each generated type by forwarding to its
//    inherent methods of the same name.
macro_rules! impl_simple_reg {
    ($($t:ty => $value:ty),+ $(,)?) => {$(
        impl SimpleRegInterface for $t {
            const VALUE_WIDTH: usize = <$t>::VALUE_WIDTH;
            type Value = $value;
            fn value(&self) -> $value { <$t>::value(self) }
            fn set_value(&self, val: $value) { <$t>::set_value(self, val) }
        }
    )+};
}

impl_simple_reg! {
    SimpleReg8  => Unsigned<8, u8>,
    SimpleReg16 => Unsigned<16, u16>,
}

// 3. the HAL: written once, generic over the interface — serves every instance.
pub struct Register<R: SimpleRegInterface>(pub R);

impl<R: SimpleRegInterface> Register<R> {
    pub fn read(&self) -> R::Value { self.0.value() }
    pub fn write(&self, v: R::Value) { self.0.set_value(v); }
    pub fn width_bits(&self) -> usize { R::VALUE_WIDTH }
}
```

The trait method names match the generated inherent names on purpose, so the
macro bodies are one-line forwards. After expansion both `SimpleReg8` and
`SimpleReg16` implement `SimpleRegInterface`, so the one `Register<R>` HAL works
for either (§8). (When the ergonomic behaviour is richer, put it in *default
methods* on the interface trait — same idea, one definition for every instance.)

---

## 7. Generating the PAC (`build.rs`)

The **library** crate that holds the PAC (the `hal` crate here) regenerates it at
build time from the memory maps — *not* the program. In `Cargo.toml`, take the
generator as **build-dependencies** and the runtime types as a normal dependency:

```toml
[dependencies]
clash-bindings = { git = "https://github.com/QBayLogic/clash-protocols-memmap", package = "clash-bindings" }

[build-dependencies]
memorymap-compiler      = { git = "https://github.com/QBayLogic/clash-protocols-memmap", package = "memorymap-compiler" }
memorymap-compiler-rust = { git = "https://github.com/QBayLogic/clash-protocols-memmap", package = "memorymap-compiler-rust" }
```

Then `build.rs` reads each `memory_maps/*.json`, `parse`s it, runs the generator,
and writes the Rust out (see the workshop's own
[`firmware/hal/build.rs`](../firmware/hal/build.rs)):

```rust
use memorymap_compiler::input_language::parse;
use memorymap_compiler_rust::testing_utils::generate_device_descs;

// for each memory_maps/*.json:
let desc = parse(&std::fs::read_to_string(&path).unwrap()).unwrap();
for (device, tokens) in generate_device_descs(&desc) {
    // write `tokens` to src/hals/<target>/<device>.rs, prefixed with the
    // needed `use clash_bindings::...` imports, then rustfmt it.
}
// … plus generate_device_instances(...) for the DeviceInstances aggregate (§4).
println!("cargo:rerun-if-changed=../memory_maps");
```

The generated tree is **git-ignored and regenerated on every build**, so it always
tracks the current memory map. Because this runs in the library, the PAC and its
`DeviceInstances` exist as soon as the crate builds — no program required. Rebuild
the Clash side first (to refresh the JSON), then build the firmware.

> A **program** may still carry its own `build.rs`, but for a different job — e.g.
> turning the memory map into a linker script (`memory_x_from_memmap`) so code and
> data land in the SoC's memories. That links the binary; it does not generate the
> PAC.

---

## 8. Use the devices from a program

Because the HAL and the generated PAC share a crate, the generated device types are
**local** — so the HAL adds its methods *directly* to them, no wrapper. Give
`SerialBytes` an ergonomic `write_byte` and a `ufmt::uWrite` impl right on the
generated type:

```rust
// hal crate: add methods + a trait impl straight onto the generated SerialBytes
use crate::hals::soc::SerialBytes;

impl SerialBytes {
    pub fn write_byte(&self, byte: u8) {
        self.set_byte(BitVector::new([byte]).unwrap());     // generated setter
    }
}
impl ufmt::uWrite for SerialBytes {
    type Error = core::convert::Infallible;
    fn write_str(&mut self, s: &str) -> Result<(), Self::Error> {
        s.bytes().for_each(|b| self.write_byte(b));
        Ok(())
    }
}
```

The program then gets every peripheral from `DeviceInstances` and drives it
directly — no wrapper, no addresses:

```rust
// application: take the devices, then use them
use hal::hals::soc::DeviceInstances;

let mut devices = unsafe { DeviceInstances::new() };
uwriteln!(devices.serial_bytes, "Hello world").unwrap();    // uWrite is on the device
```

For a device instantiated at several widths (§5) — where each instance is a
distinct type — a single `impl` won't cover them all. Use the interface trait +
macro from §6 instead: since the generated types are local to the crate, a HAL
trait `impl`s on each of them directly, and one HAL then serves every instance.

That closes the loop across the whole toolchain:

```
Clash design ─▶ memory_maps/Soc.json ─▶ (build.rs) PAC ─▶ your HAL ─▶ application
```

Change the hardware → the map changes → the PAC regenerates → the compiler points
you at every register that moved.

---

## 9. Quick reference

| I want to…                                   | Do…                                                  |
|----------------------------------------------|------------------------------------------------------|
| Get the peripherals in a program             | `unsafe { hal::hals::soc::DeviceInstances::new() }`  |
| Read a register                              | `devices.reg8.value()` (readable registers only)     |
| Write a register                             | `devices.reg8.set_value(v)` (writable registers only) |
| Make a register value                        | `Unsigned::new(x).unwrap()` / `BitVector::new([..]).unwrap()` |
| Add friendly methods to one device           | `impl` methods directly on the generated type (`impl SerialBytes`) |
| Share one HAL across monomorphic instances   | interface trait mirroring the PAC + `macro_rules!` impls |
| Walk a vector register                       | `dev.reg_volatile_iter()` / `dev.reg(i)`             |
| Regenerate the PAC                            | rebuild — `build.rs` re-runs on JSON change          |

**Gotchas**

- Generated code is **git-ignored and regenerated** — never hand-edit it; change
  the hardware / memory map instead.
- The PAC and the HAL share **one crate**, so the generated types are local: add
  friendly methods and trait impls (`ufmt::uWrite`) **directly** to them (`impl
  SerialBytes { … }`), no wrapper. For several monomorphic instances of one
  component, a single `impl` can't cover them all — use the interface trait + macro
  (§6). Keeping the PAC in a **library** (not a program) is what lets it be
  generated and inspected on its own.
- Every register access is `unsafe` + `volatile` at a raw pointer; a device is
  just a base pointer (`pub struct D(pub *mut u8)`).
- A register has a getter **or** a setter **or** both, strictly per its access
  mode — if a method is missing, check the register's access in the memory map.
- Each monomorphic instantiation of a component is its **own type** (widths shown
  in `Unsigned<8, …>`; named parametric types suffixed as `Reading_8`); use the
  trait + macro pattern (§6) to write one HAL for all of them.
- The generated tokens carry no `use` lines — the `build.rs` prepends the
  `clash_bindings` imports it needs (e.g. `Unsigned`, `BitVector`) before writing
  each file.
- PAC value types must stay byte-compatible with the Clash side — same types,
  same byte order (little-endian in this SoC).
</content>
