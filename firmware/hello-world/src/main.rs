// SPDX-License-Identifier: Apache-2.0
#![no_std]
#![no_main]

//! A software UDP loopback, and a running commentary on the serial port.
//!
//! Everything below UDP happens in the fabric: preamble, frame check sequence,
//! ARP, IPv4, ICMP and UDP are all handled there, so this program never sees a
//! header. What it does is the part that has to be software, because it is
//! policy rather than protocol -- take each datagram that arrives and send it
//! back where it came from.
//!
//! That makes it a test of the whole chain rather than of any one part. A
//! datagram that comes back proves the receive ring, the CPU's access to it, the
//! transmit buffer, and every layer of the stack under both. And because the
//! fabric answers ARP and ICMP on its own, `ping` working while this program
//! runs proves those independently of anything the CPU does.

use core::panic::PanicInfo;

use hal::hals::soc::DeviceInstances;
use riscv_rt::entry;
use ufmt::uwriteln;

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {}
}

/// Our addressing. The MAC is locally administered (bit 1 of the first octet),
/// so it cannot collide with a real vendor's.
const MAC: [u8; 6] = [0x02, 0x00, 0xde, 0xad, 0xbe, 0xef];
const IP: [u8; 4] = [10, 0, 0, 2];
const MASK: [u8; 4] = [255, 255, 255, 0];
const PORT: u16 = 7; // the echo port, which is what this is

/// Big enough for the largest packet a slot can hold.
const MTU: usize = 512;

#[entry]
fn main() -> ! {
    let mut devices = unsafe { DeviceInstances::new() };
    let eth = &devices.ethernet;

    eth.configure(MAC, IP, MASK, PORT);

    uwriteln!(devices.serial_bytes, "udp loopback: 10.0.0.2:7").unwrap();
    uwriteln!(
        devices.serial_bytes,
        "mac 02:00:de:ad:be:ef  mask 255.255.255.0"
    )
    .unwrap();

    let mut buf = [0u8; MTU];
    let mut count: u32 = 0;

    loop {
        // Poll. The peripheral reports a count rather than a flag, because
        // several packets can be waiting: the host does not wait for us.
        if eth.available() == 0 {
            continue;
        }

        let info = eth.rx_info();
        let len = eth.read(&mut buf);
        // Release the slot before transmitting, so the ring keeps draining even
        // while the reply is going out.
        eth.pop();

        eth.send(info.src_ip, info.src_port, &buf[..len]);

        count += 1;
        uwriteln!(
            devices.serial_bytes,
            "#{}: {} bytes from {}.{}.{}.{}:{} -> echoed",
            count,
            len,
            info.src_ip[0],
            info.src_ip[1],
            info.src_ip[2],
            info.src_ip[3],
            info.src_port
        )
        .unwrap();
    }
}
