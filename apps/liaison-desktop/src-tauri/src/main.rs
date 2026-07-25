#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::Mutex;

use liaison_core::{OperatingMode, SystemSnapshot};
use tauri::State;

struct AppState(Mutex<SystemSnapshot>);

#[tauri::command]
fn get_snapshot(state: State<'_, AppState>) -> Result<SystemSnapshot, String> {
    state
        .0
        .lock()
        .map(|snapshot| snapshot.clone())
        .map_err(|_| "application state is unavailable".to_string())
}

#[tauri::command]
fn set_mode(mode: OperatingMode, state: State<'_, AppState>) -> Result<SystemSnapshot, String> {
    let mut snapshot = state
        .0
        .lock()
        .map_err(|_| "application state is unavailable".to_string())?;
    snapshot.mode = mode;
    Ok(snapshot.clone())
}

fn main() {
    tauri::Builder::default()
        .manage(AppState(Mutex::new(SystemSnapshot::demo())))
        .invoke_handler(tauri::generate_handler![get_snapshot, set_mode])
        .run(tauri::generate_context!())
        .expect("failed to run Liaison desktop application");
}
