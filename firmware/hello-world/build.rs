// SPDX-License-Identifier: Apache-2.0

//! Emit a `memory.x` linker script from the SoC memory map and link it
//! alongside riscv-rt's `link.x`, so `.text`/`.data` land in the SoC memories.

use std::path::{Path, PathBuf};
use std::{env, fs};

use memorymap_compiler::memory_x_from_memmap;

fn main() {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // firmware/hello-world -> firmware -> repo root
    let repo_root = manifest.parent().and_then(|p| p.parent()).unwrap();
    let memmap = repo_root.join("memory_maps").join("Soc.json");

    let memory_x = memory_x_from_memmap(&memmap, "DataMemory", "InstructionMemory");

    let out_dir = env::var("OUT_DIR").expect("no OUT_DIR");
    fs::write(Path::new(&out_dir).join("memory.x"), memory_x).expect("write memory.x");

    println!("cargo:rustc-link-search={out_dir}");
    println!("cargo:rustc-link-arg=-Tmemory.x");
    println!("cargo:rustc-link-arg=-Tlink.x"); // from riscv-rt
    println!("cargo:rerun-if-changed={}", memmap.display());
}
