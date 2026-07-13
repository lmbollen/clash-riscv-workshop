// @generated from memory_maps/*.json by build.rs — do not edit
use clash_bindings::bitvector::BitVector;

pub struct SerialBytes(pub *mut u8);
impl SerialBytes {
    pub const BYTE_WIDTH: usize = 8;
    pub const unsafe fn new(addr: *mut u8) -> Self {
        Self(addr)
    }
    #[doc = "Receives or sends a single byte"]
    pub fn byte(&self) -> BitVector<8, 1> {
        unsafe { self.0.add(0usize).cast::<BitVector<8, 1>>().read_volatile() }
    }
    #[doc = "Receives or sends a single byte"]
    pub fn set_byte(&self, val: BitVector<8, 1>) {
        unsafe {
            self.0
                .add(0usize)
                .cast::<BitVector<8, 1>>()
                .write_volatile(val)
        }
    }
}
