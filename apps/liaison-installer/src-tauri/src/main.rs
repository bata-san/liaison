#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde::{Deserialize, Serialize};
use std::{
    env,
    fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{SystemTime, UNIX_EPOCH},
};
use tauri::{path::BaseDirectory, AppHandle, Manager};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

const SETUP_STATE_FILE: &str = "setup.json";
const SETUP_LOG_FILE: &str = "LiaisonUnifiedSetup.log";
const LOG_LIMIT_BYTES: usize = 48 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SetupState {
    role: Option<String>,
    completed: bool,
    restart_required: bool,
    message: String,
    updated_at_unix: u64,
}

impl Default for SetupState {
    fn default() -> Self {
        Self {
            role: None,
            completed: false,
            restart_required: false,
            message: "このPCの役割を選択してください。".to_owned(),
            updated_at_unix: 0,
        }
    }
}

#[derive(Debug, Serialize)]
struct SetupResult {
    role: Option<String>,
    completed: bool,
    restart_required: bool,
    message: String,
    updated_at_unix: u64,
    log: String,
    dashboard_path: Option<String>,
}

impl SetupResult {
    fn from_state(state: SetupState, log: String, dashboard_path: Option<PathBuf>) -> Self {
        Self {
            role: state.role,
            completed: state.completed,
            restart_required: state.restart_required,
            message: state.message,
            updated_at_unix: state.updated_at_unix,
            log,
            dashboard_path: dashboard_path.map(|path| path.display().to_string()),
        }
    }
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or(0)
}

fn app_data_root() -> Result<PathBuf, String> {
    #[cfg(windows)]
    {
        return env::var("APPDATA")
            .map(PathBuf::from)
            .map(|path| path.join("Liaison"))
            .map_err(|_| "APPDATAが見つからないためセットアップ状態を保存できません。".to_owned());
    }

    #[cfg(target_os = "macos")]
    {
        return env::var("HOME")
            .map(PathBuf::from)
            .map(|path| path.join("Library").join("Application Support").join("Liaison"))
            .map_err(|_| "HOMEが見つからないためセットアップ状態を保存できません。".to_owned());
    }

    #[cfg(all(not(windows), not(target_os = "macos")))]
    {
        env::var("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|_| env::var("HOME").map(|home| PathBuf::from(home).join(".config")))
            .map(|path| path.join("liaison"))
            .map_err(|_| "設定フォルダーが見つかりません。".to_owned())
    }
}

fn setup_state_path() -> Result<PathBuf, String> {
    Ok(app_data_root()?.join(SETUP_STATE_FILE))
}

fn setup_log_path() -> PathBuf {
    env::temp_dir().join(SETUP_LOG_FILE)
}

fn load_state() -> Result<SetupState, String> {
    let path = setup_state_path()?;
    if !path.exists() {
        return Ok(SetupState::default());
    }
    let text = fs::read_to_string(&path)
        .map_err(|error| format!("セットアップ状態を読み込めませんでした: {error}"))?;
    serde_json::from_str(&text)
        .map_err(|error| format!("セットアップ状態が壊れています: {error}"))
}

fn save_state(state: &SetupState) -> Result<(), String> {
    let path = setup_state_path()?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("セットアップ状態フォルダーを作成できませんでした: {error}"))?;
    }
    let json = serde_json::to_string_pretty(state)
        .map_err(|error| format!("セットアップ状態をJSONへ変換できませんでした: {error}"))?;
    fs::write(&path, format!("{json}\n"))
        .map_err(|error| format!("セットアップ状態を保存できませんでした: {error}"))
}

fn resource_path(app: &AppHandle, relative: &str) -> Result<PathBuf, String> {
    app.path()
        .resolve(relative, BaseDirectory::Resource)
        .map_err(|error| format!("同梱ファイルの場所を解決できませんでした: {error}"))
}

fn copy_tree(source: &Path, destination: &Path) -> Result<(), String> {
    fs::create_dir_all(destination)
        .map_err(|error| format!("一時セットアップフォルダーを作成できませんでした: {error}"))?;

    let entries = fs::read_dir(source)
        .map_err(|error| format!("同梱セットアップファイルを読み込めませんでした: {error}"))?;
    for entry in entries {
        let entry = entry.map_err(|error| format!("同梱ファイルを列挙できませんでした: {error}"))?;
        let source_path = entry.path();
        let destination_path = destination.join(entry.file_name());
        let file_type = entry
            .file_type()
            .map_err(|error| format!("同梱ファイル種別を確認できませんでした: {error}"))?;
        if file_type.is_dir() {
            copy_tree(&source_path, &destination_path)?;
        } else if file_type.is_file() {
            fs::copy(&source_path, &destination_path).map_err(|error| {
                format!(
                    "同梱ファイルを一時フォルダーへコピーできませんでした ({}): {error}",
                    source_path.display()
                )
            })?;
            normalize_script_file(&destination_path)?;
        }
    }
    Ok(())
}

fn normalize_script_file(path: &Path) -> Result<(), String> {
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if extension != "ps1" && extension != "sh" {
        return Ok(());
    }

    let bytes = fs::read(path)
        .map_err(|error| format!("スクリプトを読み込めませんでした ({}): {error}", path.display()))?;
    let text = String::from_utf8(bytes)
        .map_err(|error| format!("スクリプトがUTF-8ではありません ({}): {error}", path.display()))?;
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    fs::write(path, normalized.as_bytes())
        .map_err(|error| format!("スクリプトの改行を正規化できませんでした ({}): {error}", path.display()))
}

fn stage_payload(app: &AppHandle) -> Result<PathBuf, String> {
    let source = resource_path(app, "payload")?;
    if !source.is_dir() {
        return Err(format!("同梱セットアップデータが見つかりません: {}", source.display()));
    }

    let destination = env::temp_dir().join("LiaisonSetup").join("payload");
    if destination.exists() {
        fs::remove_dir_all(&destination)
            .map_err(|error| format!("古い一時セットアップデータを削除できませんでした: {error}"))?;
    }
    copy_tree(&source, &destination)?;
    Ok(destination)
}

fn read_log() -> String {
    let path = setup_log_path();
    let Ok(bytes) = fs::read(path) else {
        return String::new();
    };
    let start = bytes.len().saturating_sub(LOG_LIMIT_BYTES);
    String::from_utf8_lossy(&bytes[start..]).into_owned()
}

fn append_process_output(stdout: &[u8], stderr: &[u8]) {
    let path = setup_log_path();
    let mut text = String::new();
    if !stdout.is_empty() {
        text.push_str("\n--- setup launcher stdout ---\n");
        text.push_str(&String::from_utf8_lossy(stdout));
    }
    if !stderr.is_empty() {
        text.push_str("\n--- setup launcher stderr ---\n");
        text.push_str(&String::from_utf8_lossy(stderr));
    }
    if text.is_empty() {
        return;
    }
    let _ = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .and_then(|mut file| std::io::Write::write_all(&mut file, text.as_bytes()));
}

fn dashboard_path(app: &AppHandle) -> Result<PathBuf, String> {
    let path = resource_path(app, "payload/bin/liaison-desktop.exe")?;
    if path.is_file() {
        Ok(path)
    } else {
        Err(format!("Liaison本体が同梱されていません: {}", path.display()))
    }
}

fn powershell_path() -> PathBuf {
    env::var("SystemRoot")
        .map(PathBuf::from)
        .map(|root| root.join("System32").join("WindowsPowerShell").join("v1.0").join("powershell.exe"))
        .unwrap_or_else(|_| PathBuf::from("powershell.exe"))
}

fn run_setup_blocking(app: AppHandle, role: String, local_only: bool) -> Result<SetupResult, String> {
    if role != "server" && role != "client" {
        return Err("役割はserverまたはclientを指定してください。".to_owned());
    }

    let payload = stage_payload(&app)?;
    let launcher = payload.join("scripts").join("install-unified-role.ps1");
    if !launcher.is_file() {
        return Err(format!("役割セットアップスクリプトが見つかりません: {}", launcher.display()));
    }
    let dashboard = dashboard_path(&app)?;
    let log_path = setup_log_path();
    let _ = fs::remove_file(&log_path);

    let mut command = Command::new(powershell_path());
    command
        .arg("-NoLogo")
        .arg("-NoProfile")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-File")
        .arg(&launcher)
        .arg("-Role")
        .arg(&role)
        .arg("-PayloadRoot")
        .arg(&payload)
        .arg("-DashboardPath")
        .arg(&dashboard)
        .arg("-UnifiedLogPath")
        .arg(&log_path)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if local_only && role == "server" {
        command.arg("-LocalOnly");
    }
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);

    let output = command
        .output()
        .map_err(|error| format!("PowerShellセットアップを起動できませんでした: {error}"))?;
    append_process_output(&output.stdout, &output.stderr);

    let log = read_log();
    let lower_log = log.to_ascii_lowercase();
    let restart_required = lower_log.contains("restart windows")
        || lower_log.contains("restart the computer")
        || log.contains("Windowsを再起動")
        || log.contains("再起動してください");
    let success = output.status.success();

    let message = if success {
        if role == "server" {
            "サーバー設定が完了しました。LiaisonからこのPCを管理できます。"
        } else {
            "クライアント設定が完了しました。Liaisonでペアリングコードを入力してください。"
        }
        .to_owned()
    } else if restart_required {
        "WSLに必要なWindows機能を有効にしました。Windowsを再起動してから同じ役割で続行してください。".to_owned()
    } else {
        summarize_failure(&log).unwrap_or_else(|| {
            format!(
                "セットアップに失敗しました。PowerShell終了コード: {}",
                output.status.code().unwrap_or(-1)
            )
        })
    };

    let state = SetupState {
        role: Some(role),
        completed: success,
        restart_required,
        message,
        updated_at_unix: now_unix(),
    };
    save_state(&state)?;

    Ok(SetupResult::from_state(state, log, Some(dashboard)))
}

fn summarize_failure(log: &str) -> Option<String> {
    log.lines()
        .rev()
        .map(str::trim)
        .find(|line| {
            !line.is_empty()
                && (line.contains("Installation failed:")
                    || line.contains("Setup failed:")
                    || line.contains("セットアップに失敗")
                    || line.contains("エラー"))
        })
        .map(str::to_owned)
}

#[tauri::command]
fn get_setup_state() -> Result<SetupState, String> {
    load_state()
}

#[tauri::command]
async fn run_setup(app: AppHandle, role: String, local_only: bool) -> Result<SetupResult, String> {
    tauri::async_runtime::spawn_blocking(move || run_setup_blocking(app, role, local_only))
        .await
        .map_err(|error| format!("セットアップ処理が異常終了しました: {error}"))?
}

#[tauri::command]
fn get_setup_log() -> String {
    read_log()
}

#[tauri::command]
fn reset_setup_state() -> Result<(), String> {
    let path = setup_state_path()?;
    if path.exists() {
        fs::remove_file(path)
            .map_err(|error| format!("セットアップ状態を削除できませんでした: {error}"))?;
    }
    Ok(())
}

#[tauri::command]
fn launch_liaison(app: AppHandle) -> Result<(), String> {
    let path = dashboard_path(&app)?;
    let mut command = Command::new(&path);
    if let Some(parent) = path.parent() {
        command.current_dir(parent);
    }
    command
        .spawn()
        .map(|_| ())
        .map_err(|error| format!("Liaisonを起動できませんでした: {error}"))
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            get_setup_state,
            run_setup,
            get_setup_log,
            reset_setup_state,
            launch_liaison,
        ])
        .run(tauri::generate_context!())
        .expect("failed to run Liaison Setup");
}
