// @generated from memory_maps/*.json by build.rs — do not edit
use crate::hals::soc::devices::Ethernet;
use crate::hals::soc::devices::RotaryEncoder;
use crate::hals::soc::devices::SerialBytes;
pub struct DeviceInstances {
    pub serial_bytes: SerialBytes,
    pub rotary_encoder: RotaryEncoder,
    pub ethernet: Ethernet,
}
impl DeviceInstances {
    pub const unsafe fn new() -> Self {
        DeviceInstances {
            serial_bytes: unsafe { SerialBytes::new(0x40000000 as *mut u8) },
            rotary_encoder: unsafe { RotaryEncoder::new(0x60000000 as *mut u8) },
            ethernet: unsafe { Ethernet::new(0xA0000000 as *mut u8) },
        }
    }
}
