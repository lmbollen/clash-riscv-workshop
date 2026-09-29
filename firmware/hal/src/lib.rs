// SPDX-License-Identifier: Apache-2.0
#![no_std]

//! Device access for the workshop SoC, in two layers that share this crate.
//!
//! * [`hals`] is the **PAC** (Peripheral Access Code): typed, volatile register
//!   accessors and a [`DeviceInstances`](hals::soc::DeviceInstances) aggregate,
//!   **generated** from `memory_maps/*.json` by `build.rs`. Open
//!   `src/hals/soc/serial_bytes.rs` to see it. You never edit it — you
//!   regenerate it, and `build.rs` wipes the whole directory when you do.
//! * [`drivers`] is the **HAL** (Hardware Abstraction Layer): hand-written, one
//!   module per peripheral, mirroring the Clash modules under
//!   `Workshop.Peripheral`. Because the PAC is generated in this same crate its
//!   types are local, so a driver adds inherent methods and trait impls (like
//!   `ufmt::uWrite`) straight to the generated device type, with no wrapper.
//!
//! Keeping them in separate trees is the point: everything under `hals/` is
//! disposable output, everything under `drivers/` is source. If you are looking
//! for something to edit, it is in `drivers/`.
//!
//! A program depends on this crate, gets its peripherals from
//! [`DeviceInstances`](hals::soc::DeviceInstances) — already located at the right
//! addresses — and drives them through the driver methods.

pub mod drivers;
pub mod hals;

// The handful of driver types a program names directly, re-exported so that
// `hal::RxInfo` works as well as `hal::drivers::ethernet::RxInfo`.
pub use drivers::{EncoderChange, EncoderTracker, RxInfo, MAX_EDGES_PER_POLL};
