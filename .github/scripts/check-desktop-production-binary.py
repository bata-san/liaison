from pathlib import Path


binary_path = Path("target/release/liaison-desktop.exe")
if not binary_path.is_file():
    raise SystemExit(f"Liaison desktop executable was not generated: {binary_path}")

frontend_index = Path("apps/liaison-desktop/dist/index.html")
if not frontend_index.is_file():
    raise SystemExit(f"Liaison frontend was not generated: {frontend_index}")

binary = binary_path.read_bytes()
dev_url = "http://127.0.0.1:1420"
needles = {
    "UTF-8 development URL": dev_url.encode("utf-8"),
    "UTF-16LE development URL": dev_url.encode("utf-16le"),
}
for label, needle in needles.items():
    if needle in binary:
        raise SystemExit(
            f"{binary_path} still contains the {label}. "
            "Build liaison-desktop through the Tauri CLI, not plain cargo build."
        )

print(f"{binary_path}: production Tauri binary verified; no development URL is embedded")
