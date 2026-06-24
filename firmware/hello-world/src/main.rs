// SPDX-License-Identifier: Apache-2.0
#![no_std]
#![no_main]

use core::panic::PanicInfo;

use hal::hals::soc::DeviceInstances;
use riscv_rt::entry;
use ufmt::uwriteln;

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {}
}

#[entry]
fn main() -> ! {
    // `DeviceInstances` hands us every peripheral, already located at its
    // memory-map address — no literal addresses in the program. Each device
    // carries the HAL methods the `hal` crate added to it (here, `ufmt::uWrite`
    // on `serial_bytes`).
    let mut devices = unsafe { DeviceInstances::new() };
    uwriteln!(devices.serial_bytes, "Hello world").unwrap();
    loop {}
}
