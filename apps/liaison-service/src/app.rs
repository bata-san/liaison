use std::{
    fs,
    path::PathBuf,
    sync::{Arc, Mutex},
};

use liaison_core::{
    balanced_persistent_allocations, balanced_workspace_allocations, AppConfig, GpuAccess,
    OperatingMode, PoolCapacity, ResourceAllocation, RuntimeKind, SlotKind, SlotStatus,
    SystemSnapshot,
};
use liaison_protocol::{Command, HealthStatus, ResponseData};
use liaison_runtime::{RuntimeAdapter, RuntimeError};

pub struct ServiceApp {
    config: AppConfig,
    runtime: Arc<dyn RuntimeAdapter>,
    snapshot: Mutex<SystemSnapshot>,
    state_path: PathBuf,
}

impl ServiceApp {
    pub fn new(config: AppConfig, runtime: Arc<dyn RuntimeAdapter>) -> Result<Self, AppError> {
        let state_path = PathBuf::from(&config.data_directory).join("state.json");
        fs::create_dir_all(&config.data_directory)?;
        let app = Self {
            snapshot: Mutex::new(SystemSnapshot::new(&config)),
            config,
            runtime,
            state_path,
        };
        if app.config.persistent_autostart {
            app.start_persistent_slots()?;
        }
        app.refresh_metrics();
        app.persist_snapshot();
        Ok(app)
    }

    pub fn runtime_kind(&self) -> RuntimeKind {
        self.runtime.kind()
    }

    pub fn handle(&self, command: Command) -> Result<ResponseData, AppError> {
        match command {
            Command::Health => Ok(ResponseData::Health(HealthStatus {
                service: "liaison-service".to_owned(),
                version: env!("CARGO_PKG_VERSION").to_owned(),
                runtime: format!("{:?}", self.runtime.kind()).to_ascii_lowercase(),
            })),
            Command::Snapshot => {
                self.refresh_metrics();
                Ok(ResponseData::Snapshot(self.snapshot()?))
            }
            Command::SetMode { mode } => {
                self.set_mode(mode)?;
                Ok(ResponseData::Snapshot(self.snapshot()?))
            }
            Command::StartSlot { slot_id } => {
                self.start_slot(&slot_id)?;
                Ok(ResponseData::Snapshot(self.snapshot()?))
            }
            Command::StopSlot { slot_id } => {
                self.stop_slot(&slot_id)?;
                Ok(ResponseData::Snapshot(self.snapshot()?))
            }
            Command::ResizeSlot { slot_id, allocation } => {
                self.resize_slot(&slot_id, allocation)?;
                Ok(ResponseData::Snapshot(self.snapshot()?))
            }
            Command::Rebalance { active_workspace_slots } => {
                self.rebalance(active_workspace_slots)?;
                Ok(ResponseData::Snapshot(self.snapshot()?))
            }
            Command::ReserveGpu { slot_id, access } => {
                self.reserve_gpu(&slot_id, access)?;
                Ok(ResponseData::Snapshot(self.snapshot()?))
            }
            Command::ReleaseGpu => {
                self.release_gpu()?;
                Ok(ResponseData::Snapshot(self.snapshot()?))
            }
        }
    }

    pub fn refresh_metrics(&self) {
        let host = self.runtime.collect_host_metrics();
        let runtime_gpu = self.runtime.collect_gpu_metrics();
        let tailscale_online = self.runtime.tailscale_online();
        if let Ok(mut snapshot) = self.snapshot.lock() {
            let logical_owner = snapshot.gpu.reserved_by.clone();
            snapshot.host = host;
            snapshot.gpu = runtime_gpu;
            if logical_owner.is_some() {
                snapshot.gpu.reserved_by = logical_owner;
            }
            snapshot.tailscale_online = tailscale_online;
            for slot in &mut snapshot.slots {
                if matches!(slot.status, SlotStatus::Running | SlotStatus::Throttled) {
                    let ratio = if slot.kind == SlotKind::Persistent { 0.28 } else { 0.42 };
                    slot.memory_used_mib = (slot.allocation.memory_mib as f32 * ratio) as u32;
                    slot.cpu_percent = if slot.status == SlotStatus::Throttled { 8.0 } else { 18.0 };
                } else {
                    slot.memory_used_mib = 0;
                    slot.cpu_percent = 0.0;
                }
            }
            snapshot.recalculate_pools();
        }
    }

    fn snapshot(&self) -> Result<SystemSnapshot, AppError> {
        self.snapshot
            .lock()
            .map(|snapshot| snapshot.clone())
            .map_err(|_| AppError::State("snapshot lock poisoned".to_owned()))
    }

    fn start_persistent_slots(&self) -> Result<(), AppError> {
        let allocations = balanced_persistent_allocations(self.config.persistent_pool);
        for (index, allocation) in allocations.into_iter().enumerate() {
            self.start_specific_slot(&format!("P{}", index + 1), allocation, SlotStatus::Running)?;
        }
        Ok(())
    }

    fn start_slot(&self, slot_id: &str) -> Result<(), AppError> {
        let (kind, mode) = {
            let snapshot = self.snapshot()?;
            let slot = snapshot.slot(slot_id).ok_or_else(|| AppError::UnknownSlot(slot_id.to_owned()))?;
            (slot.kind, snapshot.mode)
        };
        if mode == OperatingMode::Maintenance {
            return Err(AppError::Rejected("slots cannot start in maintenance mode".to_owned()));
        }
        match kind {
            SlotKind::Persistent => {
                let index = persistent_index(slot_id)?;
                let allocation = balanced_persistent_allocations(self.config.persistent_pool)[index];
                self.start_specific_slot(slot_id, allocation, SlotStatus::Running)
            }
            SlotKind::Workspace => {
                if mode == OperatingMode::LocalExclusive {
                    return Err(AppError::Rejected("workspace slots cannot start in local-exclusive mode".to_owned()));
                }
                let mut active = self.active_workspace_ids()?;
                if !active.iter().any(|id| id.eq_ignore_ascii_case(slot_id)) {
                    active.push(slot_id.to_ascii_uppercase());
                }
                active.sort();
                let capacity = self.workspace_capacity_for_mode(mode);
                let status = if mode == OperatingMode::Class { SlotStatus::Throttled } else { SlotStatus::Running };
                self.apply_workspace_set(active, capacity, status)
            }
        }
    }

    fn stop_slot(&self, slot_id: &str) -> Result<(), AppError> {
        let (kind, was_active) = {
            let snapshot = self.snapshot()?;
            let slot = snapshot.slot(slot_id).ok_or_else(|| AppError::UnknownSlot(slot_id.to_owned()))?;
            (slot.kind, slot.status != SlotStatus::Stopped)
        };
        if !was_active {
            return Ok(());
        }
        if kind == SlotKind::Workspace {
            let mut active = self.active_workspace_ids()?;
            active.retain(|id| !id.eq_ignore_ascii_case(slot_id));
            let mode = self.snapshot()?.mode;
            let capacity = self.workspace_capacity_for_mode(mode);
            let status = if mode == OperatingMode::Class { SlotStatus::Throttled } else { SlotStatus::Running };
            self.apply_workspace_set(active, capacity, status)
        } else {
            self.runtime.stop_slot(slot_id)?;
            let mut snapshot = self.snapshot.lock().map_err(|_| AppError::State("snapshot lock poisoned".to_owned()))?;
            let slot = snapshot.slot_mut(slot_id).ok_or_else(|| AppError::UnknownSlot(slot_id.to_owned()))?;
            slot.status = SlotStatus::Stopped;
            slot.allocation = ResourceAllocation::stopped();
            slot.last_error = None;
            snapshot.recalculate_pools();
            drop(snapshot);
            self.persist_snapshot();
            Ok(())
        }
    }

    fn resize_slot(&self, slot_id: &str, allocation: ResourceAllocation) -> Result<(), AppError> {
        let (kind, status) = {
            let snapshot = self.snapshot()?;
            let slot = snapshot.slot(slot_id).ok_or_else(|| AppError::UnknownSlot(slot_id.to_owned()))?;
            (slot.kind, slot.status)
        };
        if status == SlotStatus::Stopped {
            return Err(AppError::Rejected("cannot resize a stopped slot".to_owned()));
        }
        let capacity = match kind {
            SlotKind::Persistent => self.config.persistent_pool,
            SlotKind::Workspace => self.workspace_capacity_for_mode(self.snapshot()?.mode),
        };
        if allocation.cpu_threads > capacity.cpu_threads || allocation.memory_mib > capacity.memory_mib {
            return Err(AppError::Rejected("requested allocation exceeds the pool capacity".to_owned()));
        }
        self.runtime.resize_slot(slot_id, &allocation)?;
        let mut snapshot = self.snapshot.lock().map_err(|_| AppError::State("snapshot lock poisoned".to_owned()))?;
        let slot = snapshot.slot_mut(slot_id).ok_or_else(|| AppError::UnknownSlot(slot_id.to_owned()))?;
        slot.allocation = allocation;
        slot.last_error = None;
        snapshot.recalculate_pools();
        drop(snapshot);
        self.persist_snapshot();
        Ok(())
    }

    fn rebalance(&self, active_workspace_slots: u8) -> Result<(), AppError> {
        if active_workspace_slots > self.config.max_workspace_slots {
            return Err(AppError::Rejected(format!(
                "active workspace count cannot exceed {}",
                self.config.max_workspace_slots
            )));
        }
        let mode = self.snapshot()?.mode;
        if matches!(mode, OperatingMode::LocalExclusive | OperatingMode::Maintenance) && active_workspace_slots > 0 {
            return Err(AppError::Rejected("workspace pool is disabled in the current mode".to_owned()));
        }
        let active = (1..=active_workspace_slots).map(|index| format!("W{index}")).collect();
        let status = if mode == OperatingMode::Class { SlotStatus::Throttled } else { SlotStatus::Running };
        self.apply_workspace_set(active, self.workspace_capacity_for_mode(mode), status)
    }

    fn set_mode(&self, mode: OperatingMode) -> Result<(), AppError> {
        let active = self.active_workspace_ids()?;
        match mode {
            OperatingMode::Remote => self.apply_workspace_set(active, self.config.workspace_pool, SlotStatus::Running)?,
            OperatingMode::Class => self.apply_workspace_set(active, self.config.class_workspace_pool, SlotStatus::Throttled)?,
            OperatingMode::LocalExclusive => self.apply_workspace_set(Vec::new(), self.config.workspace_pool, SlotStatus::Stopped)?,
            OperatingMode::Maintenance => {
                self.apply_workspace_set(Vec::new(), self.config.workspace_pool, SlotStatus::Stopped)?;
                for id in ["P1", "P2"] {
                    self.stop_slot(id)?;
                }
            }
        }
        let mut snapshot = self.snapshot.lock().map_err(|_| AppError::State("snapshot lock poisoned".to_owned()))?;
        snapshot.mode = mode;
        snapshot.recalculate_pools();
        drop(snapshot);
        self.persist_snapshot();
        Ok(())
    }

    fn reserve_gpu(&self, slot_id: &str, access: GpuAccess) -> Result<(), AppError> {
        if access == GpuAccess::None {
            return self.release_gpu();
        }
        if self.snapshot()?.mode != OperatingMode::Remote {
            return Err(AppError::Rejected("GPU reservations are only allowed in remote mode".to_owned()));
        }
        let slot = {
            let snapshot = self.snapshot()?;
            snapshot.slot(slot_id).cloned().ok_or_else(|| AppError::UnknownSlot(slot_id.to_owned()))?
        };
        if slot.kind != SlotKind::Workspace || slot.status == SlotStatus::Stopped {
            return Err(AppError::Rejected("GPU can only be reserved by an active workspace slot".to_owned()));
        }
        if let Some(previous) = self.snapshot()?.gpu.reserved_by {
            if previous != slot.id {
                let previous_slot = self.snapshot()?.slot(&previous).cloned();
                if let Some(previous_slot) = previous_slot {
                    let _ = self.runtime.set_gpu_access(&previous_slot, GpuAccess::None);
                }
            }
        }
        self.runtime.set_gpu_access(&slot, access)?;
        let mut snapshot = self.snapshot.lock().map_err(|_| AppError::State("snapshot lock poisoned".to_owned()))?;
        snapshot.set_gpu_reservation(Some(slot_id), access).map_err(|error| AppError::Rejected(error.to_string()))?;
        snapshot.recalculate_pools();
        drop(snapshot);
        self.persist_snapshot();
        Ok(())
    }

    fn release_gpu(&self) -> Result<(), AppError> {
        let owner = self.snapshot()?.gpu.reserved_by;
        if let Some(owner) = owner {
            if let Some(slot) = self.snapshot()?.slot(&owner).cloned() {
                self.runtime.set_gpu_access(&slot, GpuAccess::None)?;
            }
        }
        let mut snapshot = self.snapshot.lock().map_err(|_| AppError::State("snapshot lock poisoned".to_owned()))?;
        snapshot.set_gpu_reservation(None, GpuAccess::None).map_err(|error| AppError::Rejected(error.to_string()))?;
        drop(snapshot);
        self.persist_snapshot();
        Ok(())
    }

    fn start_specific_slot(
        &self,
        slot_id: &str,
        allocation: ResourceAllocation,
        status: SlotStatus,
    ) -> Result<(), AppError> {
        let mut slot = {
            let snapshot = self.snapshot()?;
            snapshot.slot(slot_id).cloned().ok_or_else(|| AppError::UnknownSlot(slot_id.to_owned()))?
        };
        slot.status = SlotStatus::Starting;
        slot.allocation = allocation;
        self.runtime.start_slot(&slot)?;
        let mut snapshot = self.snapshot.lock().map_err(|_| AppError::State("snapshot lock poisoned".to_owned()))?;
        let target = snapshot.slot_mut(slot_id).ok_or_else(|| AppError::UnknownSlot(slot_id.to_owned()))?;
        target.status = status;
        target.allocation = slot.allocation;
        target.last_error = None;
        target.endpoint = Some(format!("liaison://{}", slot_id.to_ascii_lowercase()));
        snapshot.recalculate_pools();
        drop(snapshot);
        self.persist_snapshot();
        Ok(())
    }

    fn active_workspace_ids(&self) -> Result<Vec<String>, AppError> {
        let snapshot = self.snapshot()?;
        let mut active: Vec<_> = snapshot.slots.iter()
            .filter(|slot| slot.kind == SlotKind::Workspace && slot.status != SlotStatus::Stopped)
            .map(|slot| slot.id.clone())
            .collect();
        active.sort();
        Ok(active)
    }

    fn apply_workspace_set(
        &self,
        mut active_ids: Vec<String>,
        capacity: PoolCapacity,
        target_status: SlotStatus,
    ) -> Result<(), AppError> {
        active_ids.sort();
        active_ids.dedup();
        if active_ids.len() > self.config.max_workspace_slots as usize {
            return Err(AppError::Rejected("too many workspace slots requested".to_owned()));
        }
        let allocations = balanced_workspace_allocations(active_ids.len(), capacity);
        let existing = self.snapshot()?;
        for slot in existing.slots.iter().filter(|slot| slot.kind == SlotKind::Workspace) {
            if let Some(index) = active_ids.iter().position(|id| id.eq_ignore_ascii_case(&slot.id)) {
                let mut allocation = allocations[index].clone();
                if existing.gpu.reserved_by.as_deref() == Some(slot.id.as_str()) {
                    allocation.gpu = slot.allocation.gpu;
                }
                if slot.status == SlotStatus::Stopped {
                    self.start_specific_slot(&slot.id, allocation, target_status)?;
                } else {
                    self.runtime.resize_slot(&slot.id, &allocation)?;
                    let mut snapshot = self.snapshot.lock().map_err(|_| AppError::State("snapshot lock poisoned".to_owned()))?;
                    let target = snapshot.slot_mut(&slot.id).ok_or_else(|| AppError::UnknownSlot(slot.id.clone()))?;
                    target.status = target_status;
                    target.allocation = allocation;
                    target.last_error = None;
                }
            } else if slot.status != SlotStatus::Stopped {
                self.runtime.stop_slot(&slot.id)?;
                let mut snapshot = self.snapshot.lock().map_err(|_| AppError::State("snapshot lock poisoned".to_owned()))?;
                let target = snapshot.slot_mut(&slot.id).ok_or_else(|| AppError::UnknownSlot(slot.id.clone()))?;
                target.status = SlotStatus::Stopped;
                target.allocation = ResourceAllocation::stopped();
                target.endpoint = None;
                target.last_error = None;
                if snapshot.gpu.reserved_by.as_deref() == Some(slot.id.as_str()) {
                    snapshot.gpu.reserved_by = None;
                }
            }
        }
        let mut snapshot = self.snapshot.lock().map_err(|_| AppError::State("snapshot lock poisoned".to_owned()))?;
        snapshot.recalculate_pools();
        drop(snapshot);
        self.persist_snapshot();
        Ok(())
    }

    fn workspace_capacity_for_mode(&self, mode: OperatingMode) -> PoolCapacity {
        match mode {
            OperatingMode::Class => self.config.class_workspace_pool,
            OperatingMode::Remote | OperatingMode::LocalExclusive | OperatingMode::Maintenance => self.config.workspace_pool,
        }
    }

    fn persist_snapshot(&self) {
        let Ok(snapshot) = self.snapshot() else { return; };
        let Ok(json) = serde_json::to_string_pretty(&snapshot) else { return; };
        if let Err(error) = fs::write(&self.state_path, json) {
            tracing::warn!(%error, path = %self.state_path.display(), "failed to persist state snapshot");
        }
    }
}

fn persistent_index(slot_id: &str) -> Result<usize, AppError> {
    match slot_id.to_ascii_uppercase().as_str() {
        "P1" => Ok(0),
        "P2" => Ok(1),
        _ => Err(AppError::UnknownSlot(slot_id.to_owned())),
    }
}

#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("runtime error: {0}")]
    Runtime(#[from] RuntimeError),
    #[error("unknown slot: {0}")]
    UnknownSlot(String),
    #[error("request rejected: {0}")]
    Rejected(String),
    #[error("service state error: {0}")]
    State(String),
}

#[cfg(test)]
mod tests {
    use super::*;
    use liaison_runtime::MockRuntime;

    fn app() -> ServiceApp {
        let mut config = AppConfig::default();
        config.data_directory = std::env::temp_dir().join(format!("liaison-test-{}", liaison_core::unix_time_ms())).display().to_string();
        ServiceApp::new(config, Arc::new(MockRuntime::new())).unwrap()
    }

    #[test]
    fn rebalance_creates_requested_number_of_workspace_slots() {
        let app = app();
        app.rebalance(3).unwrap();
        let snapshot = app.snapshot().unwrap();
        assert_eq!(snapshot.slots.iter().filter(|slot| slot.kind == SlotKind::Workspace && slot.status == SlotStatus::Running).count(), 3);
        assert_eq!(snapshot.pools.iter().find(|pool| pool.id == "workspace").unwrap().cpu_allocated_threads, 38);
    }

    #[test]
    fn local_exclusive_keeps_persistent_slots_running() {
        let app = app();
        app.rebalance(2).unwrap();
        app.set_mode(OperatingMode::LocalExclusive).unwrap();
        let snapshot = app.snapshot().unwrap();
        assert!(snapshot.slots.iter().filter(|slot| slot.kind == SlotKind::Workspace).all(|slot| slot.status == SlotStatus::Stopped));
        assert!(snapshot.slots.iter().filter(|slot| slot.kind == SlotKind::Persistent).all(|slot| slot.status == SlotStatus::Running));
    }
}
