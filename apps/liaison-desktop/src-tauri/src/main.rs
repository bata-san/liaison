#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::{
    fs,
    net::SocketAddr,
    path::PathBuf,
    sync::Mutex,
};

use liaison_client::{ClientError, LiaisonClient};
use liaison_core::{GpuAccess, OperatingMode, ResourceAllocation, SystemSnapshot};
use liaison_protocol::{Command, ResponseData};
use tauri::State;

struct AppState {
    client: Mutex<LiaisonClient>,
}

#[derive(serde::Serialize)]
struct ConnectionSettings {
    address: String,
    token: String,
    path: String,
}

fn current_client(state: &State<'_, AppState>) -> Result<LiaisonClient, String> {
    state
        .client
        .lock()
        .map(|client| client.clone())
        .map_err(|_| "client connection lock was poisoned".to_owned())
}

#[tauri::command]
fn get_connection_settings(state: State<'_, AppState>) -> Result<ConnectionSettings, String> {
    let client = current_client(&state)?;
    let path = client_config_path()?;
    let mut address = client.address().to_owned();
    let mut token = std::env::var("LIAISON_TOKEN").unwrap_or_default();

    if let Ok(text) = fs::read_to_string(&path) {
        if let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) {
            if let Some(saved_address) = value.get("address").and_then(serde_json::Value::as_str) {
                address = saved_address.to_owned();
            }
            if let Some(saved_token) = value.get("token").and_then(serde_json::Value::as_str) {
                token = saved_token.to_owned();
            }
        }
    }

    Ok(ConnectionSettings {
        address,
        token,
        path: path.display().to_string(),
    })
}

#[tauri::command]
fn save_connection(
    address: String,
    token: String,
    state: State<'_, AppState>,
) -> Result<String, String> {
    let address = normalize_address(&address)?;
    let token = token.trim().to_owned();
    if token.len() < 16 {
        return Err("接続トークンは16文字以上で入力してください。".to_owned());
    }

    let path = client_config_path()?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            format!("接続設定フォルダーを作成できませんでした: {error}")
        })?;
    }

    let mut value = fs::read_to_string(&path)
        .ok()
        .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
        .filter(serde_json::Value::is_object)
        .unwrap_or_else(|| serde_json::json!({}));
    let object = value
        .as_object_mut()
        .ok_or_else(|| "接続設定をJSONオブジェクトとして作成できませんでした。".to_owned())?;
    object.insert("version".to_owned(), serde_json::json!(1));
    object.insert("server_name".to_owned(), serde_json::json!("manual"));
    object.insert("address".to_owned(), serde_json::json!(address));
    object.insert("token".to_owned(), serde_json::json!(token));
    object.insert("transport".to_owned(), serde_json::json!("manual"));

    let json = serde_json::to_string_pretty(&value)
        .map_err(|error| format!("接続設定をJSONへ変換できませんでした: {error}"))?;
    fs::write(&path, format!("{json}\n"))
        .map_err(|error| format!("接続設定を書き込めませんでした: {error}"))?;

    let address = object
        .get("address")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("127.0.0.1:57841")
        .to_owned();
    let token = object
        .get("token")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let mut client = state
        .client
        .lock()
        .map_err(|_| "client connection lock was poisoned".to_owned())?;
    *client = LiaisonClient::new(address, token);

    Ok(path.display().to_string())
}

#[tauri::command]
fn get_snapshot(state: State<'_, AppState>) -> Result<SystemSnapshot, String> {
    let client = current_client(&state)?;
    snapshot_from(
        client
            .send(Command::Snapshot)
            .map_err(|error| connection_error(&client, error))?,
    )
}

#[tauri::command]
fn set_mode(mode: OperatingMode, state: State<'_, AppState>) -> Result<SystemSnapshot, String> {
    let client = current_client(&state)?;
    snapshot_from(
        client
            .send(Command::SetMode { mode })
            .map_err(|error| error.to_string())?,
    )
}

#[tauri::command]
fn rebalance(
    active_workspace_slots: u8,
    state: State<'_, AppState>,
) -> Result<SystemSnapshot, String> {
    let client = current_client(&state)?;
    snapshot_from(
        client
            .send(Command::Rebalance {
                active_workspace_slots,
            })
            .map_err(|error| error.to_string())?,
    )
}

#[tauri::command]
fn start_slot(slot_id: String, state: State<'_, AppState>) -> Result<SystemSnapshot, String> {
    let client = current_client(&state)?;
    snapshot_from(
        client
            .send(Command::StartSlot { slot_id })
            .map_err(|error| error.to_string())?,
    )
}

#[tauri::command]
fn stop_slot(slot_id: String, state: State<'_, AppState>) -> Result<SystemSnapshot, String> {
    let client = current_client(&state)?;
    snapshot_from(
        client
            .send(Command::StopSlot { slot_id })
            .map_err(|error| error.to_string())?,
    )
}

#[tauri::command]
fn resize_slot(
    slot_id: String,
    cpu_threads: u16,
    memory_mib: u32,
    state: State<'_, AppState>,
) -> Result<SystemSnapshot, String> {
    let client = current_client(&state)?;
    snapshot_from(
        client
            .send(Command::ResizeSlot {
                slot_id,
                allocation: ResourceAllocation {
                    cpu_threads,
                    memory_mib,
                    gpu: GpuAccess::None,
                },
            })
            .map_err(|error| error.to_string())?,
    )
}

#[tauri::command]
fn assign_worker(
    slot_id: String,
    cpu_threads: u16,
    memory_mib: u32,
    gpu: GpuAccess,
    state: State<'_, AppState>,
) -> Result<SystemSnapshot, String> {
    let client = current_client(&state)?;
    snapshot_from(
        client
            .send(Command::AssignWorker {
                slot_id,
                allocation: ResourceAllocation {
                    cpu_threads,
                    memory_mib,
                    gpu,
                },
            })
            .map_err(|error| error.to_string())?,
    )
}

#[tauri::command]
fn reserve_gpu(
    slot_id: String,
    access: GpuAccess,
    state: State<'_, AppState>,
) -> Result<SystemSnapshot, String> {
    let client = current_client(&state)?;
    snapshot_from(
        client
            .send(Command::ReserveGpu { slot_id, access })
            .map_err(|error| error.to_string())?,
    )
}

#[tauri::command]
fn release_gpu(state: State<'_, AppState>) -> Result<SystemSnapshot, String> {
    let client = current_client(&state)?;
    snapshot_from(
        client
            .send(Command::ReleaseGpu)
            .map_err(|error| error.to_string())?,
    )
}

fn normalize_address(value: &str) -> Result<String, String> {
    let value = value.trim();
    if value.is_empty() {
        return Err("サーバーIPまたはホスト名を入力してください。".to_owned());
    }
    if value.parse::<SocketAddr>().is_ok() {
        return Ok(value.to_owned());
    }
    let (host, port) = value.rsplit_once(':').ok_or_else(|| {
        "接続先は IP:ポート または ホスト名:ポート の形式で入力してください。".to_owned()
    })?;
    if host.trim().is_empty() {
        return Err("サーバーIPまたはホスト名が空です。".to_owned());
    }
    if host.contains(':') {
        return Err("IPv6は [アドレス]:ポート の形式で入力してください。".to_owned());
    }
    let port = port
        .parse::<u16>()
        .map_err(|_| "ポート番号は1〜65535で入力してください。".to_owned())?;
    if port == 0 {
        return Err("ポート番号は1〜65535で入力してください。".to_owned());
    }
    Ok(format!("{}:{}", host.trim(), port))
}

fn client_config_path() -> Result<PathBuf, String> {
    if let Ok(path) = std::env::var("LIAISON_CLIENT_CONFIG") {
        return Ok(PathBuf::from(path));
    }
    #[cfg(windows)]
    {
        let app_data = std::env::var("APPDATA")
            .map_err(|_| "APPDATAが見つからないため接続設定を保存できません。".to_owned())?;
        return Ok(PathBuf::from(app_data).join("Liaison").join("client.json"));
    }
    #[cfg(target_os = "macos")]
    {
        let home = std::env::var("HOME")
            .map_err(|_| "HOMEが見つからないため接続設定を保存できません。".to_owned())?;
        return Ok(PathBuf::from(home)
            .join("Library")
            .join("Application Support")
            .join("Liaison")
            .join("client.json"));
    }
    #[cfg(all(not(windows), not(target_os = "macos")))]
    {
        let base = std::env::var("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|_| std::env::var("HOME").map(|home| PathBuf::from(home).join(".config")))
            .map_err(|_| "設定フォルダーが見つかりません。".to_owned())?;
        Ok(base.join("liaison").join("client.json"))
    }
}

fn connection_error(client: &LiaisonClient, error: ClientError) -> String {
    let address = client.address();
    match error {
        ClientError::Io(io_error) if io_error.kind() == std::io::ErrorKind::ConnectionRefused => {
            if address.starts_with("127.0.0.1:") || address.starts_with("localhost:") {
                format!(
                    "接続先 {address} でLiaison Serverが起動していません。下の接続設定からサーバーIPを入力できます。"
                )
            } else {
                format!(
                    "接続先 {address} に拒否されました。サーバーの起動状態、Tailscale接続、IPとポートを確認してください。"
                )
            }
        }
        ClientError::Io(io_error) if io_error.kind() == std::io::ErrorKind::TimedOut => format!(
            "接続先 {address} が応答しません。サーバーとTailscaleがオンラインか確認してください。"
        ),
        other => format!("接続先 {address}: {other}"),
    }
}

fn snapshot_from(data: ResponseData) -> Result<SystemSnapshot, String> {
    match data {
        ResponseData::Snapshot(snapshot) => Ok(snapshot),
        _ => Err("service returned an unexpected response".to_owned()),
    }
}

fn main() {
    tauri::Builder::default()
        .manage(AppState {
            client: Mutex::new(LiaisonClient::from_environment()),
        })
        .invoke_handler(tauri::generate_handler![
            get_connection_settings,
            save_connection,
            get_snapshot,
            set_mode,
            rebalance,
            start_slot,
            stop_slot,
            resize_slot,
            assign_worker,
            reserve_gpu,
            release_gpu,
        ])
        .run(tauri::generate_context!())
        .expect("failed to run Liaison desktop application");
}
