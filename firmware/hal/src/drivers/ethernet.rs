// SPDX-License-Identifier: Apache-2.0

//! Ergonomic driver methods for the generated `Ethernet` peripheral: a UDP socket.
//!
//! The hardware below this is a full Ethernet stack — preamble, frame check
//! sequence, ARP, IPv4, ICMP and UDP are all handled in the fabric, and none of
//! it is this layer's business. What reaches the CPU is a payload and who sent
//! it, and what leaves it is a payload and where to send it.
//!
//! Two things are worth knowing about the shape of it, because they are not
//! symmetric and the asymmetry is deliberate:
//!
//! * **Receive is a ring** of four packet slots. Software does not control when
//!   frames arrive, and a host will happily send several back to back. So
//!   [`Ethernet::available`] returns a count, not a flag, and the buffer window
//!   shows whichever packet is at the head until [`Ethernet::pop`] moves it on.
//! * **Transmit is a single buffer.** The CPU decides when to send, so there is
//!   nothing to queue against.
//!
//! Packets arrive whole or not at all: one that overran a slot, or arrived with
//! the ring full, was dropped in the fabric rather than truncated. So a length
//! read out of here is a real length, and there is no partial packet to detect.

use clash_bindings::{bitvector::BitVector, unsigned::Unsigned};

/// Build an `Unsigned<16, u16>` from a `u16`.
///
/// `Unsigned::new` cannot be used at full width: its bounds check is
/// `val <= !(!0 << N)`, and for `N` equal to the backing type's width that
/// shift overflows and fails to compile. `new_unchecked` is documented as
/// always safe in exactly this case -- every `u16` is a valid 16-bit unsigned --
/// so the check it skips is the one that cannot fail.
fn u16_reg(val: u16) -> Unsigned<16, u16> {
    unsafe { Unsigned::new_unchecked(val) }
}

use crate::hals::soc::Ethernet;

/// A received packet: how big it is and who sent it.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct RxInfo {
    /// Payload bytes.
    pub length: u16,
    /// Sender's IPv4 address.
    pub src_ip: [u8; 4],
    /// Sender's UDP port.
    pub src_port: u16,
}

impl Ethernet {
    /// Tell the stack who we are. Until this is called the stack has an
    /// all-zero MAC and IP and will not answer anything.
    ///
    /// The subnet mask is what the stack uses to decide whether a destination is
    /// on our segment or needs a gateway, so it matters even on a two-machine
    /// link.
    pub fn configure(&self, mac: [u8; 6], ip: [u8; 4], subnet_mask: [u8; 4], port: u16) {
        for (i, b) in mac.iter().enumerate() {
            self.set_mac(i, BitVector::new([*b]).unwrap());
        }
        for (i, b) in ip.iter().enumerate() {
            self.set_ip(i, BitVector::new([*b]).unwrap());
        }
        for (i, b) in subnet_mask.iter().enumerate() {
            self.set_subnet_mask(i, BitVector::new([*b]).unwrap());
        }
        self.set_local_port(u16_reg(port));
    }

    /// How many received packets are waiting. This is the poll.
    pub fn available(&self) -> u8 {
        self.rx_available().into_inner()
    }

    /// About the packet at the head of the ring. Only meaningful when
    /// [`Self::available`] is non-zero.
    pub fn rx_info(&self) -> RxInfo {
        let mut src_ip = [0u8; 4];
        for (i, slot) in src_ip.iter_mut().enumerate() {
            *slot = self.rx_src_ip(i).unwrap().into_inner()[0];
        }
        RxInfo {
            length: self.rx_length().into_inner(),
            src_ip,
            src_port: self.rx_src_port().into_inner(),
        }
    }

    /// Copy the head packet's payload into `out`, returning how many bytes were
    /// written.
    ///
    /// Reads go a word at a time because the buffer is 32 bits wide on the bus;
    /// the tail of a packet whose length is not a multiple of four is masked off
    /// here rather than left for the caller to notice.
    pub fn read(&self, out: &mut [u8]) -> usize {
        let len = (self.rx_length().into_inner() as usize).min(out.len());
        for i in 0..len.div_ceil(4) {
            let word = self.rx_buffer(i).unwrap().into_inner();
            for lane in 0..4 {
                let at = i * 4 + lane;
                if at < len {
                    out[at] = word[lane];
                }
            }
        }
        len
    }

    /// Release the head packet and move the window to the next one.
    ///
    /// Do this once per packet, after reading it. Forgetting to means the ring
    /// fills and further packets are dropped in the fabric.
    pub fn pop(&self) {
        self.set_rx_pop(true);
    }

    /// Whether a transmission is still in progress. The transmit buffer must not
    /// be written while it is.
    pub fn busy(&self) -> bool {
        self.tx_busy()
    }

    /// Send `payload` to `ip`:`port`.
    ///
    /// Blocks until any previous transmission has finished, then fills the
    /// buffer and hands it to the stack. The payload must fit the buffer; longer
    /// slices are truncated rather than silently wrapping.
    pub fn send(&self, ip: [u8; 4], port: u16, payload: &[u8]) -> usize {
        while self.busy() {}

        let len = payload.len().min(Self::TX_BUFFER_LEN * 4);
        for i in 0..len.div_ceil(4) {
            let mut word = [0u8; 4];
            for lane in 0..4 {
                let at = i * 4 + lane;
                if at < len {
                    word[lane] = payload[at];
                }
            }
            self.set_tx_buffer(i, BitVector::new(word).unwrap());
        }

        for (i, b) in ip.iter().enumerate() {
            self.set_tx_dst_ip(i, BitVector::new([*b]).unwrap());
        }
        self.set_tx_dst_port(u16_reg(port));
        self.set_tx_length(u16_reg(len as u16));
        self.set_tx_send(true);
        len
    }
}
