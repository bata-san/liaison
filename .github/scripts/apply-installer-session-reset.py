from pathlib import Path


RUST_PATH = Path("apps/liaison-installer/src-tauri/src/main.rs")
UI_PATH = Path("apps/liaison-installer/src/main.ts")
MARKER = "fn begin_setup_session() -> Result<(), String>"


def replace_required(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Expected one {label} replacement, found {count}")
    return text.replace(old, new, 1)


rust = RUST_PATH.read_text(encoding="utf-8-sig")
if MARKER not in rust:
    helper = r'''
fn setup_session_file_names() -> &'static [&'static str] {
    &[
        SETUP_LOG_FILE,
        "LiaisonServerInstall.log",
        "LiaisonServerCore.stdout.log",
        "LiaisonServerCore.stderr.log",
        "LiaisonServerLauncher.log",
    ]
}

fn remove_setup_session_files() {
    let temp = env::temp_dir();
    for name in setup_session_file_names() {
        let _ = fs::remove_file(temp.join(name));
    }
}

fn current_install_timestamp() -> Option<u64> {
    let metadata = env::current_exe().ok()?.metadata().ok()?;
    [metadata.created().ok(), metadata.modified().ok()]
        .into_iter()
        .flatten()
        .filter_map(|value| value.duration_since(UNIX_EPOCH).ok())
        .map(|value| value.as_secs())
        .max()
}

fn state_predates_current_install(state: &SetupState) -> bool {
    if state.updated_at_unix == 0 {
        return false;
    }
    current_install_timestamp()
        .map(|installed_at| installed_at > state.updated_at_unix.saturating_add(2))
        .unwrap_or(false)
}

fn begin_setup_session() -> Result<(), String> {
    remove_setup_session_files();
    let path = setup_log_path();
    fs::write(&path, format!("SESSION|{}\n", now_unix()))
        .map_err(|error| format!("セットアップログを初期化できませんでした: {error}"))
}

'''
    rust = replace_required(
        rust,
        "fn load_state() -> Result<SetupState, String> {",
        helper + "fn load_state() -> Result<SetupState, String> {",
        "session helper insertion",
    )

    old_load = '''    let text = fs::read_to_string(&path)
        .map_err(|error| format!("セットアップ状態を読み込めませんでした: {error}"))?;
    serde_json::from_str(&text)
        .map_err(|error| format!("セットアップ状態が壊れています: {error}"))
}'''
    new_load = '''    let text = fs::read_to_string(&path)
        .map_err(|error| format!("セットアップ状態を読み込めませんでした: {error}"))?;
    let state: SetupState = serde_json::from_str(&text)
        .map_err(|error| format!("セットアップ状態が壊れています: {error}"))?;

    // MSI reinstall/update does not automatically remove AppData or Temp files.
    // Treat state older than the currently installed executable as stale.
    if state_predates_current_install(&state) {
        remove_setup_session_files();
        let _ = fs::remove_file(&path);
        return Ok(SetupState::default());
    }
    Ok(state)
}'''
    rust = replace_required(rust, old_load, new_load, "stale install state reset")

    old_read = '''    let start = bytes.len().saturating_sub(LOG_LIMIT_BYTES);
    String::from_utf8_lossy(&bytes[start..]).into_owned()
}'''
    new_read = '''    let start = bytes.len().saturating_sub(LOG_LIMIT_BYTES);
    let text = String::from_utf8_lossy(&bytes[start..]).into_owned();
    if let Some(index) = text.rfind("SESSION|") {
        return text[index..].to_owned();
    }
    text
}'''
    rust = replace_required(rust, old_read, new_read, "latest session log selection")

    old_run = '''    let payload = stage_payload(&app)?;
    let launcher = payload.join("scripts").join("install-unified-role.ps1");
    if !launcher.is_file() {
        return Err(format!("役割セットアップスクリプトが見つかりません: {}", launcher.display()));
    }
    let dashboard = dashboard_path(&app)?;
    let log_path = setup_log_path();
    let _ = fs::remove_file(&log_path);'''
    new_run = '''    // Clear every log from the previous attempt before staging or elevation.
    // The SESSION marker also prevents accidental replay if another process keeps a
    // previous file handle open while the new setup starts.
    begin_setup_session()?;

    let payload = stage_payload(&app)?;
    let launcher = payload.join("scripts").join("install-unified-role.ps1");
    if !launcher.is_file() {
        return Err(format!("役割セットアップスクリプトが見つかりません: {}", launcher.display()));
    }
    let dashboard = dashboard_path(&app)?;
    let log_path = setup_log_path();'''
    rust = replace_required(rust, old_run, new_run, "setup session start")

    old_reset = '''    if path.exists() {
        fs::remove_file(path)
            .map_err(|error| format!("セットアップ状態を削除できませんでした: {error}"))?;
    }
    Ok(())'''
    new_reset = '''    if path.exists() {
        fs::remove_file(path)
            .map_err(|error| format!("セットアップ状態を削除できませんでした: {error}"))?;
    }
    remove_setup_session_files();
    Ok(())'''
    rust = replace_required(rust, old_reset, new_reset, "reset log cleanup")

    RUST_PATH.write_text(rust, encoding="utf-8", newline="\n")
    print(f"{RUST_PATH}: setup session isolation applied")
else:
    print(f"{RUST_PATH}: setup session isolation already applied")

ui = UI_PATH.read_text(encoding="utf-8-sig")
old_filter = '.filter((line) => line.trim().length > 0 && !line.includes("PROGRESS|"));'
new_filter = '.filter((line) => line.trim().length > 0 && !line.includes("PROGRESS|") && !line.includes("SESSION|"));'
if new_filter not in ui:
    ui = replace_required(ui, old_filter, new_filter, "session marker UI filter")
    UI_PATH.write_text(ui, encoding="utf-8", newline="\n")
    print(f"{UI_PATH}: session marker hidden")
else:
    print(f"{UI_PATH}: session marker already hidden")
