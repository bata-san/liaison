#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use liaison_client::{ClientError, LiaisonClient};
use liaison_core::{GpuAccess, OperatingMode, ResourceAllocation, SystemSnapshot};
use liaison_protocol::{Command, ResponseData};
use tauri::State;

struct AppState {
    client: LiaisonClient,
}

#[tauri::command]
fn get_snapshot(state: State<'_, AppState>) -> Result<SystemSnapshot, String> {
    snapshot_from(
        state
            .client
            .send(Command::Snapshot)
            .map_err(|error| connection_error(&state.client, error))?,
    )
}

#[tauri::command]
fn set_mode(mode: OperatingMode, state: State<'_, AppState>) -> Result<SystemSnapshot, String> {
    snapshot_from(
        state
            .client
            .send(Command::SetMode { mode })
            .map_err(|error| error.to_string())?,
    )
}

#[tauri::command]
fn rebalance(
    active_workspace_slots: u8,
    state: State<'_, AppState>,
) -> Result<SystemSnapshot, String> {
    snapshot_from(
        state
            .client
            .send(Command::Rebalance {
                active_workspace_slots,
            })
            .map_err(|error| error.to_string())?,
    )
}

#[tauri::command]
fn start_slot(slot_id: String, state: State<'_, AppState>) -> Result<SystemSnapshot, String> {
    snapshot_from(
        state
            .client
            .send(Command::StartSlot { slot_id })
            .map_err(|error| error.to_string())?,
    )
}

#[tauri::command]
fn stop_slot(slot_id: String, state: State<'_, AppState>) -> Result<SystemSnapshot, String> {
    snapshot_from(
        state
            .client
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
    snapshot_from(
        state
            .client
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
    snapshot_from(
        state
            .client
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
    snapshot_from(
        state
            .client
            .send(Command::ReserveGpu { slot_id, access })
            .map_err(|error| error.to_string())?,
    )
}

#[tauri::command]
fn release_gpu(state: State<'_, AppState>) -> Result<SystemSnapshot, String> {
    snapshot_from(
        state
            .client
            .send(Command::ReleaseGpu)
            .map_err(|error| error.to_string())?,
    )
}

fn connection_error(client: &LiaisonClient, error: ClientError) -> String {
    let address = client.address();
    match error {
        ClientError::Io(io_error) if io_error.kind() == std::io::ErrorKind::ConnectionRefused => {
            if address.starts_with("127.0.0.1:") || address.starts_with("localhost:") {
                format!(
                    "接続先 {address} でLiaison Serverが起動していません。このMacをサーバーにする場合はServer版を再セットアップしてください。別のPCがサーバーの場合は、そのサーバーで生成されたliaison-client.jsonを入れ直してください。"
                )
            } else {
                format!(
                    "接続先 {address} に拒否されました。サーバーの起動状態、Tailscale接続、liaison-client.jsonを確認してください。"
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
            client: LiaisonClient::from_environment(),
        })
        .invoke_handler(tauri::generate_handler![
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
