// SPDX-License-Identifier: Apache-2.0
#![no_std]

//! Device access for the workshop SoC.
//!
//! [`hals`] is the **PAC** (Peripheral Access Code): typed, volatile register
//! accessors and a [`DeviceInstances`](hals::soc::DeviceInstances) aggregate,
//! **generated** from `memory_maps/*.json` by `build.rs`. Open
//! `src/hals/soc/serial_bytes.rs` to see it. You never edit it — you regenerate it.
//!
//! The **HAL** (Hardware Abstraction Layer) — ergonomic driver methods added
//! directly to the generated device types — is what you add in step 4 of the
//! workshop.

pub mod hals;
