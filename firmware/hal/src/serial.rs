// SPDX-License-Identifier: Apache-2.0

//! Ergonomic driver methods for the generated `SerialBytes` peripheral.
//!
//! Because the PAC is generated in this same crate, `SerialBytes` is a local
//! type — so the HAL adds inherent methods and trait impls (`ufmt::uWrite`)
//! directly to it, with no wrapper.

use clash_bindings::bitvector::BitVector;

use crate::hals::soc::SerialBytes;

impl SerialBytes {
    /// Send a single byte out the serial port.
    pub fn write_byte(&self, byte: u8) {
        // Turn the `u8` into the register's value type and call the generated
        // setter (see the code-generator cheatsheet §3).
        self.set_byte(BitVector::new([byte]).unwrap());
    }
}

impl ufmt::uWrite for SerialBytes {
    type Error = core::convert::Infallible;

    fn write_str(&mut self, s: &str) -> Result<(), Self::Error> {
        s.bytes().for_each(|b| self.write_byte(b));
        Ok(())
    }
}
