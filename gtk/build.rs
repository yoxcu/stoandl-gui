//! Build script: compile Blueprint UI (`ui/*.blp`) to GTK `.ui`, gather the CSS,
//! and bundle everything into a GResource that `main.rs` registers at startup.
//!
//! Kept a pure-Cargo build (no Meson): `blueprint-compiler` is the only external
//! tool, invoked in `batch-compile` mode. `glib-compile-resources` (from
//! `glib-build-tools`, provided by libglib2.0-dev-bin) does the final bundling.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let ui_src = Path::new("ui");
    let res_dir = out_dir.join("res"); // GResource source root
    let ui_out = res_dir.join("ui"); // compiled .ui land here
    fs::create_dir_all(&ui_out).expect("create res/ui dir");

    // 1. Collect .blp inputs.
    let mut blps: Vec<PathBuf> = Vec::new();
    if ui_src.is_dir() {
        for entry in fs::read_dir(ui_src).expect("read ui/") {
            let p = entry.expect("dir entry").path();
            if p.extension().and_then(|e| e.to_str()) == Some("blp") {
                println!("cargo:rerun-if-changed={}", p.display());
                blps.push(p);
            }
        }
    }
    println!("cargo:rerun-if-changed=ui");

    // 2. Compile .blp -> .ui with blueprint-compiler batch-compile.
    if !blps.is_empty() {
        let status = Command::new("blueprint-compiler")
            .arg("batch-compile")
            .arg(&ui_out) // OUTPUT_DIR
            .arg(ui_src) // INPUT_DIR (for relative naming)
            .args(&blps)
            .status()
            .unwrap_or_else(|e| {
                panic!(
                    "failed to run blueprint-compiler ({e}); \
                     install it: apt-get install blueprint-compiler"
                )
            });
        assert!(status.success(), "blueprint-compiler failed");
    }

    // 3. Copy static resources (CSS) into the GResource root.
    fs::copy("resources/style.css", res_dir.join("style.css")).expect("copy style.css");
    println!("cargo:rerun-if-changed=resources/style.css");
    println!("cargo:rerun-if-changed=resources/resources.gresource.xml");

    // 4. Bundle. The .gresource.xml <file> paths resolve under res_dir.
    glib_build_tools::compile_resources(
        &[res_dir.to_str().expect("utf8 res_dir")],
        "resources/resources.gresource.xml",
        "stoandl.gresource",
    );
}
