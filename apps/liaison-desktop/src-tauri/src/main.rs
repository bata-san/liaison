#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use liaison_client::LiaisonClient;
use liaison_core::{GpuAccess, OperatingMode, SystemSnapshot};
use liaison_protocol::{Command, ResponseData};
use tauri::State;

struct AppState {
    client: LiaisonClient,
}

#[tauri::command]
fn get_snapshot(state: State<'_, AppState>) -> Result<SystemSnapshot, String> {
    snapshot_from(state.client.send(Command::Snapshot).map_err(|error| error.to_string())?)
}

#[tauri::command]
fn set_mode(mode: OperatingMode, state: State<'_, AppState>) -> Result<SystemSnapshot, String> {
    snapshot_from(state.client.send(Command::SetMode { mode }).map_err(|error| error.to_string())?)
}

#[tauri::command]
fn rebalance(active_workspace_slots: u8, state: State<'_, AppState>) -> Result<SystemSnapshot, String> {
    snapshot_from(
        state.client
            .send(Command::Rebalance { active_workspace_slots })
            .map_err(|error| error.to_string())?,
    )
}

#[tauri::command]
fn start_slot(slot_id: String, state: State<'_, AppState>) -> Result<SystemSnapshot, String> {
    snapshot_from(state.client.send(Command::StartSlot { slot_id }).map_err(|error| error.to_string())?)
}

#[tauri::command]
fn stop_slot(slot_id: String, state: State<'_, AppState>) -> Result<SystemSnapshot, String> {
    snapshot_from(state.client.send(Command::StopSlot { slot_id }).map_err(|error| error.to_string())?)
}

#[tauri::command]
fn reserve_gpu(slot_id: String, access: GpuAccess, state: State<'_, AppState>) -> Result<SystemSnapshot, String> {
    snapshot_from(
        state.client
            .send(Command::ReserveGpu { slot_id, access })
            .map_err(|error| error.to_string())?,
    )
}

#[tauri::command]
fn release_gpu(state: State<'_, AppState>) -> Result<SystemSnapshot, String> {
    snapshot_from(state.client.send(Command::ReleaseGpu).map_err(|error| error.to_string())?)
}

fn snapshot_from(data: ResponseData) -> Result<SystemSnapshot, String> {
    match data {
        ResponseData::Snapshot(snapshot) => Ok(snapshot),
        _ => Err("service returned an unexpected response".to_owned()),
    }
}

fn main() {
    tauri::Builder::default()
        .manage(AppState { client: LiaisonClient::from_environment() })
        .invoke_handler(tauri::generate_handler![
            get_snapshot,
            set_mode,
            rebalance,
            start_slot,
            stop_slot,
            reserve_gpu,
            release_gpu,
        ])
        .run(tauri::generate_context!())
        .expect("failed to run Liaison desktop application");
}
