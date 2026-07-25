use std::{env, fs, path::PathBuf};

const ICON_SIZE: u32 = 32;

fn main() {
    let manifest_dir = PathBuf::from(
        env::var_os("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR must be set"),
    );
    let icon_path = manifest_dir.join("icons").join("icon.ico");

    if !icon_path.exists() {
        fs::create_dir_all(icon_path.parent().expect("icon path has a parent"))
            .expect("failed to create icon directory");
        fs::write(&icon_path, generate_icon()).expect("failed to generate Windows icon");
    }

    tauri_build::build();
}

fn generate_icon() -> Vec<u8> {
    let pixel_bytes = ICON_SIZE * ICON_SIZE * 4;
    let mask_stride = ((ICON_SIZE + 31) / 32) * 4;
    let mask_bytes = mask_stride * ICON_SIZE;
    let image_bytes = 40 + pixel_bytes + mask_bytes;
    let image_offset = 6 + 16;

    let mut bytes = Vec::with_capacity((image_offset + image_bytes) as usize);

    // ICONDIR
    push_u16(&mut bytes, 0);
    push_u16(&mut bytes, 1);
    push_u16(&mut bytes, 1);

    // ICONDIRENTRY
    bytes.push(ICON_SIZE as u8);
    bytes.push(ICON_SIZE as u8);
    bytes.push(0);
    bytes.push(0);
    push_u16(&mut bytes, 1);
    push_u16(&mut bytes, 32);
    push_u32(&mut bytes, image_bytes);
    push_u32(&mut bytes, image_offset);

    // BITMAPINFOHEADER. ICO stores XOR and AND planes, so height is doubled.
    push_u32(&mut bytes, 40);
    push_i32(&mut bytes, ICON_SIZE as i32);
    push_i32(&mut bytes, (ICON_SIZE * 2) as i32);
    push_u16(&mut bytes, 1);
    push_u16(&mut bytes, 32);
    push_u32(&mut bytes, 0);
    push_u32(&mut bytes, pixel_bytes);
    push_i32(&mut bytes, 0);
    push_i32(&mut bytes, 0);
    push_u32(&mut bytes, 0);
    push_u32(&mut bytes, 0);

    // BGRA pixels, bottom-up. The icon is a mint tile with a dark L mark.
    for y in (0..ICON_SIZE).rev() {
        for x in 0..ICON_SIZE {
            let edge = x < 2 || y < 2 || x >= ICON_SIZE - 2 || y >= ICON_SIZE - 2;
            let mark = (10..=14).contains(&x) && (7..=24).contains(&y)
                || (10..=23).contains(&x) && (20..=24).contains(&y);
            let (red, green, blue) = if edge {
                (43, 83, 71)
            } else if mark {
                (8, 17, 14)
            } else {
                (104, 229, 183)
            };
            bytes.extend_from_slice(&[blue, green, red, 255]);
        }
    }

    // Fully opaque AND mask.
    bytes.resize((image_offset + image_bytes) as usize, 0);
    bytes
}

fn push_u16(bytes: &mut Vec<u8>, value: u16) {
    bytes.extend_from_slice(&value.to_le_bytes());
}

fn push_u32(bytes: &mut Vec<u8>, value: u32) {
    bytes.extend_from_slice(&value.to_le_bytes());
}

fn push_i32(bytes: &mut Vec<u8>, value: i32) {
    bytes.extend_from_slice(&value.to_le_bytes());
}
