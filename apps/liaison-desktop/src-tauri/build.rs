use std::{env, fs, path::PathBuf};

const ICON_SIZE: u32 = 32;

fn main() {
    let manifest_dir = PathBuf::from(
        env::var_os("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR must be set"),
    );
    let icon_directory = manifest_dir.join("icons");
    let windows_icon_path = icon_directory.join("icon.ico");
    let png_icon_path = icon_directory.join("icon.png");

    fs::create_dir_all(&icon_directory).expect("failed to create icon directory");
    if !windows_icon_path.exists() {
        fs::write(&windows_icon_path, generate_windows_icon())
            .expect("failed to generate Windows icon");
    }
    if !png_icon_path.exists() {
        fs::write(&png_icon_path, generate_png_icon()).expect("failed to generate PNG icon");
    }

    tauri_build::build();
}

fn icon_rgb(x: u32, y: u32) -> (u8, u8, u8) {
    let edge = x < 2 || y < 2 || x >= ICON_SIZE - 2 || y >= ICON_SIZE - 2;
    let mark = (10..=14).contains(&x) && (7..=24).contains(&y)
        || (10..=23).contains(&x) && (20..=24).contains(&y);
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
    let mask_stride = ((ICON_SIZE + 31) / 32) * 4;
    let mask_bytes = mask_stride * ICON_SIZE;
    let image_bytes = 40 + pixel_bytes + mask_bytes;
    let image_offset = 6 + 16;

    let mut bytes = Vec::with_capacity((image_offset + image_bytes) as usize);

    // ICONDIR
    push_u16_le(&mut bytes, 0);
    push_u16_le(&mut bytes, 1);
    push_u16_le(&mut bytes, 1);

    // ICONDIRENTRY
    bytes.push(ICON_SIZE as u8);
    bytes.push(ICON_SIZE as u8);
    bytes.push(0);
    bytes.push(0);
    push_u16_le(&mut bytes, 1);
    push_u16_le(&mut bytes, 32);
    push_u32_le(&mut bytes, image_bytes);
    push_u32_le(&mut bytes, image_offset);

    // BITMAPINFOHEADER. ICO stores XOR and AND planes, so height is doubled.
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

    // BGRA pixels, bottom-up.
    for y in (0..ICON_SIZE).rev() {
        for x in 0..ICON_SIZE {
            let (red, green, blue) = icon_rgb(x, y);
            bytes.extend_from_slice(&[blue, green, red, 255]);
        }
    }

    // Fully opaque AND mask.
    bytes.resize((image_offset + image_bytes) as usize, 0);
    bytes
}

fn generate_png_icon() -> Vec<u8> {
    let mut raw = Vec::with_capacity((ICON_SIZE * (1 + ICON_SIZE * 4)) as usize);
    for y in 0..ICON_SIZE {
        raw.push(0); // PNG filter: None
        for x in 0..ICON_SIZE {
            let (red, green, blue) = icon_rgb(x, y);
            raw.extend_from_slice(&[red, green, blue, 255]);
        }
    }

    // A zlib stream containing one uncompressed DEFLATE block.
    let length: u16 = raw
        .len()
        .try_into()
        .expect("the generated icon must fit in one DEFLATE block");
    let mut compressed = Vec::with_capacity(raw.len() + 11);
    compressed.extend_from_slice(&[0x78, 0x01]);
    compressed.push(0x01); // BFINAL=1, BTYPE=00
    compressed.extend_from_slice(&length.to_le_bytes());
    compressed.extend_from_slice(&(!length).to_le_bytes());
    compressed.extend_from_slice(&raw);
    compressed.extend_from_slice(&adler32(&raw).to_be_bytes());

    let mut png = Vec::new();
    png.extend_from_slice(&[137, 80, 78, 71, 13, 10, 26, 10]);

    let mut ihdr = Vec::with_capacity(13);
    ihdr.extend_from_slice(&ICON_SIZE.to_be_bytes());
    ihdr.extend_from_slice(&ICON_SIZE.to_be_bytes());
    ihdr.extend_from_slice(&[8, 6, 0, 0, 0]); // 8-bit RGBA
    push_png_chunk(&mut png, b"IHDR", &ihdr);
    push_png_chunk(&mut png, b"IDAT", &compressed);
    push_png_chunk(&mut png, b"IEND", &[]);
    png
}

fn push_png_chunk(output: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    output.extend_from_slice(&(data.len() as u32).to_be_bytes());
    output.extend_from_slice(kind);
    output.extend_from_slice(data);
    let mut crc_input = Vec::with_capacity(kind.len() + data.len());
    crc_input.extend_from_slice(kind);
    crc_input.extend_from_slice(data);
    output.extend_from_slice(&crc32(&crc_input).to_be_bytes());
}

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = 0xffff_ffffu32;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            let mask = 0u32.wrapping_sub(crc & 1);
            crc = (crc >> 1) ^ (0xedb8_8320 & mask);
        }
    }
    !crc
}

fn adler32(bytes: &[u8]) -> u32 {
    const MODULUS: u32 = 65_521;
    let mut a = 1u32;
    let mut b = 0u32;
    for byte in bytes {
        a = (a + u32::from(*byte)) % MODULUS;
        b = (b + a) % MODULUS;
    }
    (b << 16) | a
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
