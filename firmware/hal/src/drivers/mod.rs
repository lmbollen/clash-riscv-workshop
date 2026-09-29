// SPDX-License-Identifier: Apache-2.0

//! Hand-written drivers, one module per peripheral.
//!
//! These mirror the Clash side one for one — `Workshop.Peripheral.Serial` has
//! [`serial`], `Workshop.Peripheral.Encoder` has [`encoder`],
//! `Workshop.Peripheral.Ethernet` has [`ethernet`] — so there is exactly one
//! place to look for the software half of any device.
//!
//! Each of them adds inherent methods, and sometimes trait impls, *directly* to
//! the generated type from [`crate::hals`]. That is possible because the PAC is
//! generated into this same crate, which makes its types local: no newtype
//! wrapper, no trait to route through, and `DeviceInstances` hands out devices
//! that already have the driver methods on them.
//!
//! The division of labour is the same everywhere. The PAC knows addresses and
//! register layouts and nothing else; the driver knows what the registers *mean*
//! and does the parts that are policy rather than protocol — turning a wrapping
//! counter into a relative position, or a buffer window into a UDP socket.

pub mod encoder;
pub mod ethernet;
pub mod serial;

pub use encoder::{EncoderChange, EncoderTracker, MAX_EDGES_PER_POLL};
pub use ethernet::RxInfo;
