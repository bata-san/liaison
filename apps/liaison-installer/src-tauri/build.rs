use base64::{engine::general_purpose::STANDARD, Engine as _};
use std::{fs, path::PathBuf};

fn main() {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let icons = manifest.join("icons");
    let icon = icons.join("icon.ico");
    fs::create_dir_all(&icons).expect("failed to create installer icon directory");
    let bytes = STANDARD
        .decode(include_str!("icons/icon.ico.b64").trim())
        .expect("failed to decode installer icon");
    fs::write(&icon, bytes).expect("failed to write installer icon");
    println!("cargo:rerun-if-changed=icons/icon.ico.b64");
    tauri_build::build();
}
