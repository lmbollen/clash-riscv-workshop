// @generated from memory_maps/*.json by build.rs — do not edit
use crate::hals::soc::devices::SerialBytes;
pub struct DeviceInstances {
    pub serial_bytes: SerialBytes,
}
impl DeviceInstances {
    pub const unsafe fn new() -> Self {
        DeviceInstances {
            serial_bytes: unsafe { SerialBytes::new(0xC0000000 as *mut u8) },
        }
    }
}
