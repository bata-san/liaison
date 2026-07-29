use std::{fs, path::PathBuf};

const ICON_SIZE: u32 = 32;

fn main() {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let icons = manifest.join("icons");
    let icon = icons.join("icon.ico");

    fs::create_dir_all(&icons).expect("failed to create installer icon directory");
    fs::write(&icon, generate_windows_icon()).expect("failed to write installer icon");

    println!("cargo:rerun-if-changed=build.rs");
    tauri_build::build();
}

fn icon_rgb(x: u32, y: u32) -> (u8, u8, u8) {
    let edge = x < 2 || y < 2 || x >= ICON_SIZE - 2 || y >= ICON_SIZE - 2;
    let mark = (8..=13).contains(&x) && (7..=24).contains(&y)
        || (8..=23).contains(&x) && (19..=24).contains(&y);

    if edge {
        (43, 83, 71)
    } else if mark {
        (8, 17, 14)
    } else {
        (104, 229, 183)
    }
}

fn generate_windows_icon() -> Vec<u8> {
    let pixel_bytes = ICON_SIZE * ICON_SIZE * 4;
    let mask_stride = ICON_SIZE.div_ceil(32) * 4;
    let mask_bytes = mask_stride * ICON_SIZE;
    let image_bytes = 40 + pixel_bytes + mask_bytes;
    let image_offset = 6 + 16;

    let mut bytes = Vec::with_capacity((image_offset + image_bytes) as usize);

    push_u16_le(&mut bytes, 0);
    push_u16_le(&mut bytes, 1);
    push_u16_le(&mut bytes, 1);

    bytes.push(ICON_SIZE as u8);
    bytes.push(ICON_SIZE as u8);
    bytes.push(0);
    bytes.push(0);
    push_u16_le(&mut bytes, 1);
    push_u16_le(&mut bytes, 32);
    push_u32_le(&mut bytes, image_bytes);
    push_u32_le(&mut bytes, image_offset);

    push_u32_le(&mut bytes, 40);
    push_i32_le(&mut bytes, ICON_SIZE as i32);
    push_i32_le(&mut bytes, (ICON_SIZE * 2) as i32);
    push_u16_le(&mut bytes, 1);
    push_u16_le(&mut bytes, 32);
    push_u32_le(&mut bytes, 0);
    push_u32_le(&mut bytes, pixel_bytes);
    push_i32_le(&mut bytes, 0);
    push_i32_le(&mut bytes, 0);
    push_u32_le(&mut bytes, 0);
    push_u32_le(&mut bytes, 0);

    for y in (0..ICON_SIZE).rev() {
        for x in 0..ICON_SIZE {
            let (red, green, blue) = icon_rgb(x, y);
            bytes.extend_from_slice(&[blue, green, red, 255]);
        }
    }

    bytes.resize((image_offset + image_bytes) as usize, 0);
    bytes
}

fn push_u16_le(bytes: &mut Vec<u8>, value: u16) {
    bytes.extend_from_slice(&value.to_le_bytes());
}

fn push_u32_le(bytes: &mut Vec<u8>, value: u32) {
    bytes.extend_from_slice(&value.to_le_bytes());
}

fn push_i32_le(bytes: &mut Vec<u8>, value: i32) {
    bytes.extend_from_slice(&value.to_le_bytes());
}
