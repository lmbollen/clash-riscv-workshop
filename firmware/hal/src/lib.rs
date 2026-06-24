// SPDX-License-Identifier: Apache-2.0
#![no_std]

//! Device access for the workshop SoC, in two layers that share this crate.
//!
//! * [`hals`] is the **PAC** (Peripheral Access Code): typed, volatile register
//!   accessors and a [`DeviceInstances`](hals::soc::DeviceInstances) aggregate,
//!   **generated** from `memory_maps/*.json` by `build.rs`. Open
//!   `src/hals/soc/serial_bytes.rs` to see it. You never edit it — you
//!   regenerate it.
//! * The **HAL** (Hardware Abstraction Layer): hand-written driver methods added
//!   *directly* to the generated device types (see `serial.rs`). Because the PAC
//!   is generated in this same crate, its types are local, so the HAL can give
//!   them inherent methods and trait impls (like `ufmt::uWrite`) with no wrapper.
//!
//! A program depends on this crate, gets its peripherals from
//! [`DeviceInstances`](hals::soc::DeviceInstances) — already located at the right
//! addresses — and drives them through those HAL methods.

pub mod hals;

// Adds ergonomic methods + `ufmt::uWrite` to the generated `SerialBytes`.
mod serial;
