// SPDX-License-Identifier: Apache-2.0

//! Generates the Peripheral Access Code from the workshop's memory maps
//! (`memory_maps/*.json`, produced by the Clash side in `Workshop.MemoryMaps`).
//!
//! One module is generated per *target* (memory map). Within it there is one
//! module per device (a struct with typed, volatile register accessors, e.g.
//! `SerialBytes::set_byte`) plus a `DeviceInstances` struct that constructs every
//! peripheral at its memory-map address. Devices tagged `no-generate` (the
//! CPU-internal instruction/data memories) are skipped. Output is written as real
//! source files under `src/hals/<target>/` so it can be read and inspected:
//!
//! ```text
//! src/hals/
//!   mod.rs            pub mod soc;
//!   soc/
//!     mod.rs          pub mod serial_bytes; …  pub use instances::*;
//!     serial_bytes.rs pub struct SerialBytes { … }
//!     instances.rs    pub struct DeviceInstances { pub serial: SerialBytes, … }
//! ```

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::{env, fs};

use memorymap_compiler::input_language::parse;
use memorymap_compiler::ir::deduplicate::HalShared;
use memorymap_compiler::ir::input_to_ir::IrInputMapping;
use memorymap_compiler::ir::types::IrCtx;
use memorymap_compiler_rust::generate_device_instances;
use memorymap_compiler_rust::testing_utils::generate_device_descs;

const HEADER: &str = "// @generated from memory_maps/*.json by build.rs — do not edit\n";

fn main() {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // firmware/hal -> firmware -> repo root
    let repo_root = manifest.parent().and_then(|p| p.parent()).unwrap();
    let memmap_dir = repo_root.join("memory_maps");

    let hals = manifest.join("src").join("hals");
    let _ = fs::remove_dir_all(&hals);
    fs::create_dir_all(&hals).expect("create src/hals");

    let mut targets = Vec::new();
    if memmap_dir.exists() {
        for entry in fs::read_dir(&memmap_dir).expect("read memory_maps/ (run the Clash build first)") {
            let path = entry.unwrap().path();
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            // e.g. memory_maps/Soc.json -> target "Soc" -> module "soc"
            let target = path.file_stem().unwrap().to_str().unwrap().to_string();
            let module = snake_case(&target);

            let desc = parse(&fs::read_to_string(&path).expect("read memory map"))
                .expect("parse memory map");

            let target_dir = hals.join(&module);
            fs::create_dir_all(&target_dir).unwrap();

            // Devices tagged "no-generate" (the CPU-internal memories) get no
            // driver. `generate_device_descs` does not filter these itself, so we
            // skip them here, matching on DeviceDesc.name (the key it returns).
            let skip: HashSet<String> = desc
                .devices
                .values()
                .filter(|d| d.tags.iter().any(|t| t == "no-generate"))
                .map(|d| d.name.clone())
                .collect();

            let mut mod_rs = String::from(HEADER);
            for (device, tokens) in generate_device_descs(&desc) {
                if skip.contains(&device) {
                    continue;
                }
                let dev_mod = snake_case(&device);
                let file = format!(
                    "{HEADER}use clash_bindings::bitvector::BitVector;\n\n{tokens}\n"
                );
                let file_path = target_dir.join(format!("{dev_mod}.rs"));
                fs::write(&file_path, file).unwrap();
                rustfmt(&file_path);
                mod_rs.push_str(&format!("pub mod {dev_mod};\npub use {dev_mod}::*;\n"));
            }

            // `DeviceInstances`: one field per peripheral, each constructed at its
            // absolute address. We build the IR ourselves (what `testing_utils`
            // hides for device descs); instances need no monomorphization, and
            // `no-generate` *instances* are skipped inside the generator.
            let mut ctx = IrCtx::new();
            let mut mapping = IrInputMapping::default();
            let hal = ctx.add_memory_map_desc(&mut mapping, &desc);
            let shared = HalShared {
                deduped_types: Vec::new(),
                type_mapping: HashMap::new(),
                // Empty => the generator references devices as
                // `crate::hals::<target>::devices::<Device>` (not `shared_devices`).
                deduped_devices: Vec::new(),
                device_mappings: HashMap::new(),
            };
            let instances =
                generate_device_instances(&ctx, &shared, &target, hal.tree_elem_range.handles());

            // The generator emits `use crate::hals::<target>::devices::<Device>;`.
            // Our layout is flat (devices re-exported from the target module), so
            // add a `devices` shim that forwards to it. Keep `DeviceInstances` in
            // its own submodule to avoid glob clashes with the device re-exports.
            mod_rs.push_str("pub mod devices {\n    pub use super::*;\n}\n");
            mod_rs.push_str("mod instances;\npub use instances::*;\n");
            write_fmt(&target_dir.join("mod.rs"), &mod_rs);

            let inst_path = target_dir.join("instances.rs");
            fs::write(&inst_path, format!("{HEADER}{instances}\n")).unwrap();
            rustfmt(&inst_path);

            targets.push(module);
        }
    }

    let mut hals_mod = String::from(HEADER);
    for t in &targets {
        hals_mod.push_str(&format!("pub mod {t};\n"));
    }
    write_fmt(&hals.join("mod.rs"), &hals_mod);

    println!("cargo:rerun-if-changed={}", memmap_dir.display());
    println!("cargo:rerun-if-changed=build.rs");
}

fn write_fmt(path: &Path, contents: &str) {
    fs::write(path, contents).unwrap();
    rustfmt(path);
}

/// Pretty-print a generated file (best effort — `proc_macro2` emits one long line).
fn rustfmt(path: &Path) {
    let _ = Command::new("rustfmt")
        .args(["--edition", "2021"])
        .arg(path)
        .status();
}

/// `SerialBytes` -> `serial_bytes`
fn snake_case(s: &str) -> String {
    let mut out = String::new();
    for (i, c) in s.char_indices() {
        if c.is_ascii_uppercase() {
            if i != 0 {
                out.push('_');
            }
            out.push(c.to_ascii_lowercase());
        } else {
            out.push(c);
        }
    }
    out
}
