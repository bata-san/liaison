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
            Command::ResizeSlot {
                slot_id,
                allocation,
            } => {
                self.resize_slot(&slot_id, allocation)?;
                Ok(ResponseData::Snapshot(self.snapshot()?))
            }
            Command::AssignWorker {
                slot_id,
                allocation,
            } => {
                self.assign_worker(&slot_id, allocation)?;
                Ok(ResponseData::Snapshot(self.snapshot()?))
            }
            Command::Rebalance {
                active_workspace_slots,
            } => {
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
            let exclusive_owner = snapshot
                .slots
                .iter()
                .find(|slot| {
                    slot.status != SlotStatus::Stopped
                        && slot.allocation.gpu == GpuAccess::Exclusive
                })
                .map(|slot| slot.id.clone());

            snapshot.host = host;
            snapshot.gpu = runtime_gpu;
            snapshot.gpu.reserved_by = exclusive_owner;
            snapshot.tailscale_online = tailscale_online;
            for slot in &mut snapshot.slots {
                if matches!(slot.status, SlotStatus::Running | SlotStatus::Throttled) {
                    let ratio = if slot.kind == SlotKind::Persistent {
                        0.28
                    } else {
                        0.42
                    };
                    slot.memory_used_mib = (slot.allocation.memory_mib as f32 * ratio) as u32;
                    slot.cpu_percent = if slot.status == SlotStatus::Throttled {
                        8.0
                    } else {
                        18.0
                    };
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
            self.start_specific_slot(
                &format!("P{}", index + 1),
                allocation,
                SlotStatus::Running,
            )?;
        }
        Ok(())
    }

    fn start_slot(&self, slot_id: &str) -> Result<(), AppError> {
        let snapshot = self.snapshot()?;
        let slot = snapshot
            .slot(slot_id)
            .cloned()
            .ok_or_else(|| AppError::UnknownSlot(slot_id.to_owned()))?;
        if slot.status != SlotStatus::Stopped {
            return Ok(());
        }
        if snapshot.mode == OperatingMode::Maintenance {
            return Err(AppError::Rejected(
                "slots cannot start in maintenance mode".to_owned(),
            ));
        }

        match slot.kind {
            SlotKind::Persistent => {
                let index = persistent_index(slot_id)?;
                let allocation =
                    balanced_persistent_allocations(self.config.persistent_pool)[index];
                self.start_specific_slot(slot_id, allocation, SlotStatus::Running)
            }
            SlotKind::Workspace => {
                if snapshot.mode == OperatingMode::LocalExclusive {
                    return Err(AppError::Rejected(
                        "workspace slots cannot start in local-exclusive mode".to_owned(),
                    ));
                }
                let capacity = self.workspace_capacity_for_mode(snapshot.mode);
                let used_cpu: u16 = snapshot
                    .slots
                    .iter()
                    .filter(|candidate| {
                        candidate.kind == SlotKind::Workspace
                            && candidate.status != SlotStatus::Stopped
                    })
                    .map(|candidate| candidate.allocation.cpu_threads)
                    .sum();
                let used_memory: u32 = snapshot
                    .slots
                    .iter()
                    .filter(|candidate| {
                        candidate.kind == SlotKind::Workspace
                            && candidate.status != SlotStatus::Stopped
                    })
                    .map(|candidate| candidate.allocation.memory_mib)
                    .sum();
                let free_cpu = capacity.cpu_threads.saturating_sub(used_cpu);
                let free_memory = capacity.memory_mib.saturating_sub(used_memory);
                if free_cpu == 0 || free_memory == 0 {
                    return Err(AppError::Rejected(
                        "workspace pool has no free CPU or memory".to_owned(),
                    ));
                }
                self.assign_worker(
                    slot_id,
                    ResourceAllocation {
                        cpu_threads: free_cpu.min(4),
                        memory_mib: free_memory.min(4_096),
                        gpu: GpuAccess::None,
                    },
                )
            }
        }
    }

    fn stop_slot(&self, slot_id: &str) -> Result<(), AppError> {
        let slot = self
            .snapshot()?
            .slot(slot_id)
            .cloned()
            .ok_or_else(|| AppError::UnknownSlot(slot_id.to_owned()))?;
        if slot.status == SlotStatus::Stopped {
            return Ok(());
        }

        self.runtime.stop_slot(slot_id)?;
        let mut snapshot = self
            .snapshot
            .lock()
            .map_err(|_| AppError::State("snapshot lock poisoned".to_owned()))?;
        let target = snapshot
            .slot_mut(slot_id)
            .ok_or_else(|| AppError::UnknownSlot(slot_id.to_owned()))?;
        target.status = SlotStatus::Stopped;
        target.allocation = ResourceAllocation::stopped();
        target.endpoint = None;
        target.last_error = None;
        Self::sync_gpu_owner(&mut snapshot);
        snapshot.recalculate_pools();
        drop(snapshot);
        self.persist_snapshot();
        Ok(())
    }

    fn assign_worker(
        &self,
        slot_id: &str,
        allocation: ResourceAllocation,
    ) -> Result<(), AppError> {
        let existing = self.snapshot()?;
        let slot = existing
            .slot(slot_id)
            .cloned()
            .ok_or_else(|| AppError::UnknownSlot(slot_id.to_owned()))?;
        if slot.kind != SlotKind::Workspace {
            return Err(AppError::Rejected(
                "custom worker allocations are only available for workspace slots".to_owned(),
            ));
        }
        if matches!(
            existing.mode,
            OperatingMode::LocalExclusive | OperatingMode::Maintenance
        ) {
            return Err(AppError::Rejected(
                "workspace pool is disabled in the current mode".to_owned(),
            ));
        }
        if allocation.gpu != GpuAccess::None && existing.mode != OperatingMode::Remote {
            return Err(AppError::Rejected(
                "GPU access is only available in remote mode".to_owned(),
            ));
        }

        let capacity = self.workspace_capacity_for_mode(existing.mode);
        self.validate_workspace_allocation(&existing, slot_id, allocation, capacity)?;

        if allocation.gpu == GpuAccess::Shared {
            let exclusive_owner = existing.slots.iter().find(|candidate| {
                candidate.kind == SlotKind::Workspace
                    && candidate.status != SlotStatus::Stopped
                    && !candidate.id.eq_ignore_ascii_case(slot_id)
                    && candidate.allocation.gpu == GpuAccess::Exclusive
            });
            if let Some(owner) = exclusive_owner {
                return Err(AppError::Rejected(format!(
                    "GPU is exclusively assigned to {}",
                    owner.id
                )));
            }
        }

        let gpu_to_clear: Vec<_> = if allocation.gpu == GpuAccess::Exclusive {
            existing
                .slots
                .iter()
                .filter(|candidate| {
                    candidate.kind == SlotKind::Workspace
                        && candidate.status != SlotStatus::Stopped
                        && !candidate.id.eq_ignore_ascii_case(slot_id)
                        && candidate.allocation.gpu != GpuAccess::None
                })
                .cloned()
                .collect()
        } else {
            Vec::new()
        };
        for other in &gpu_to_clear {
            self.runtime.set_gpu_access(other, GpuAccess::None)?;
        }

        let target_status = if existing.mode == OperatingMode::Class {
            SlotStatus::Throttled
        } else {
            SlotStatus::Running
        };
        let mut updated = slot.clone();
        updated.status = SlotStatus::Starting;
        updated.allocation = allocation;

        if slot.status == SlotStatus::Stopped {
            self.runtime.start_slot(&updated)?;
        } else if slot.allocation.gpu != allocation.gpu {
            self.runtime.set_gpu_access(&updated, allocation.gpu)?;
        } else {
            self.runtime.resize_slot(slot_id, &allocation)?;
        }

        let mut snapshot = self
            .snapshot
            .lock()
            .map_err(|_| AppError::State("snapshot lock poisoned".to_owned()))?;
        for other in gpu_to_clear {
            if let Some(target) = snapshot.slot_mut(&other.id) {
                target.allocation.gpu = GpuAccess::None;
            }
        }
        let target = snapshot
            .slot_mut(slot_id)
            .ok_or_else(|| AppError::UnknownSlot(slot_id.to_owned()))?;
        target.status = target_status;
        target.allocation = allocation;
        target.last_error = None;
        target.endpoint = Some(format!("liaison://{}", slot_id.to_ascii_lowercase()));
        Self::sync_gpu_owner(&mut snapshot);
        snapshot.recalculate_pools();
        drop(snapshot);
        self.persist_snapshot();
        Ok(())
    }

    fn resize_slot(
        &self,
        slot_id: &str,
        allocation: ResourceAllocation,
    ) -> Result<(), AppError> {
        let existing = self.snapshot()?;
        let slot = existing
            .slot(slot_id)
            .cloned()
            .ok_or_else(|| AppError::UnknownSlot(slot_id.to_owned()))?;
        if slot.kind == SlotKind::Workspace {
            return self.assign_worker(slot_id, allocation);
        }
        if slot.status == SlotStatus::Stopped {
            return Err(AppError::Rejected(
                "cannot resize a stopped slot".to_owned(),
            ));
        }
        if allocation.gpu != GpuAccess::None {
            return Err(AppError::Rejected(
                "persistent slots cannot receive GPU access".to_owned(),
            ));
        }
        if allocation.cpu_threads == 0 || allocation.memory_mib == 0 {
            return Err(AppError::Rejected(
                "CPU and memory allocations must be greater than zero".to_owned(),
            ));
        }
        let other_cpu: u16 = existing
            .slots
            .iter()
            .filter(|candidate| {
                candidate.kind == SlotKind::Persistent
                    && candidate.status != SlotStatus::Stopped
                    && !candidate.id.eq_ignore_ascii_case(slot_id)
            })
            .map(|candidate| candidate.allocation.cpu_threads)
            .sum();
        let other_memory: u32 = existing
            .slots
            .iter()
            .filter(|candidate| {
                candidate.kind == SlotKind::Persistent
                    && candidate.status != SlotStatus::Stopped
                    && !candidate.id.eq_ignore_ascii_case(slot_id)
            })
            .map(|candidate| candidate.allocation.memory_mib)
            .sum();
        if other_cpu.saturating_add(allocation.cpu_threads)
            > self.config.persistent_pool.cpu_threads
            || other_memory.saturating_add(allocation.memory_mib)
                > self.config.persistent_pool.memory_mib
        {
            return Err(AppError::Rejected(
                "persistent allocation exceeds the persistent pool".to_owned(),
            ));
        }

        self.runtime.resize_slot(slot_id, &allocation)?;
        let mut snapshot = self
            .snapshot
            .lock()
            .map_err(|_| AppError::State("snapshot lock poisoned".to_owned()))?;
        let target = snapshot
            .slot_mut(slot_id)
            .ok_or_else(|| AppError::UnknownSlot(slot_id.to_owned()))?;
        target.allocation = allocation;
        target.last_error = None;
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
        if matches!(
            mode,
            OperatingMode::LocalExclusive | OperatingMode::Maintenance
        ) && active_workspace_slots > 0
        {
            return Err(AppError::Rejected(
                "workspace pool is disabled in the current mode".to_owned(),
            ));
        }
        let active = (1..=active_workspace_slots)
            .map(|index| format!("W{index}"))
            .collect();
        let status = if mode == OperatingMode::Class {
            SlotStatus::Throttled
        } else {
            SlotStatus::Running
        };
        self.apply_workspace_set(active, self.workspace_capacity_for_mode(mode), status)
    }

    fn set_mode(&self, mode: OperatingMode) -> Result<(), AppError> {
        match mode {
            OperatingMode::Remote => {
                self.fit_active_workspaces_to_capacity(
                    self.config.workspace_pool,
                    SlotStatus::Running,
                )?;
            }
            OperatingMode::Class => {
                self.release_gpu()?;
                self.fit_active_workspaces_to_capacity(
                    self.config.class_workspace_pool,
                    SlotStatus::Throttled,
                )?;
            }
            OperatingMode::LocalExclusive => {
                self.apply_workspace_set(
                    Vec::new(),
                    self.config.workspace_pool,
                    SlotStatus::Stopped,
                )?;
            }
            OperatingMode::Maintenance => {
                self.apply_workspace_set(
                    Vec::new(),
                    self.config.workspace_pool,
                    SlotStatus::Stopped,
                )?;
                for id in ["P1", "P2"] {
                    self.stop_slot(id)?;
                }
            }
        }

        let mut snapshot = self
            .snapshot
            .lock()
            .map_err(|_| AppError::State("snapshot lock poisoned".to_owned()))?;
        snapshot.mode = mode;
        self.sync_workspace_pool_capacity(&mut snapshot, mode);
        snapshot.recalculate_pools();
        drop(snapshot);
        self.persist_snapshot();
        Ok(())
    }

    fn reserve_gpu(&self, slot_id: &str, access: GpuAccess) -> Result<(), AppError> {
        if access == GpuAccess::None {
            let existing = self.snapshot()?;
            let slot = existing
                .slot(slot_id)
                .cloned()
                .ok_or_else(|| AppError::UnknownSlot(slot_id.to_owned()))?;
            if slot.kind != SlotKind::Workspace || slot.status == SlotStatus::Stopped {
                return Err(AppError::Rejected(
                    "GPU access can only be changed for an active worker".to_owned(),
                ));
            }
            let mut allocation = slot.allocation;
            allocation.gpu = GpuAccess::None;
            return self.assign_worker(slot_id, allocation);
        }

        let existing = self.snapshot()?;
        let slot = existing
            .slot(slot_id)
            .cloned()
            .ok_or_else(|| AppError::UnknownSlot(slot_id.to_owned()))?;
        if slot.kind != SlotKind::Workspace || slot.status == SlotStatus::Stopped {
            return Err(AppError::Rejected(
                "GPU can only be assigned to an active workspace slot".to_owned(),
            ));
        }
        let mut allocation = slot.allocation;
        allocation.gpu = access;
        self.assign_worker(slot_id, allocation)
    }

    fn release_gpu(&self) -> Result<(), AppError> {
        let assigned: Vec<_> = self
            .snapshot()?
            .slots
            .into_iter()
            .filter(|slot| {
                slot.kind == SlotKind::Workspace
                    && slot.status != SlotStatus::Stopped
                    && slot.allocation.gpu != GpuAccess::None
            })
            .collect();
        for slot in &assigned {
            self.runtime.set_gpu_access(slot, GpuAccess::None)?;
        }

        let mut snapshot = self
            .snapshot
            .lock()
            .map_err(|_| AppError::State("snapshot lock poisoned".to_owned()))?;
        for slot in &mut snapshot.slots {
            if slot.kind == SlotKind::Workspace {
                slot.allocation.gpu = GpuAccess::None;
            }
        }
        snapshot.gpu.reserved_by = None;
        snapshot.recalculate_pools();
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
        let mut slot = self
            .snapshot()?
            .slot(slot_id)
            .cloned()
            .ok_or_else(|| AppError::UnknownSlot(slot_id.to_owned()))?;
        slot.status = SlotStatus::Starting;
        slot.allocation = allocation;
        self.runtime.start_slot(&slot)?;
        let mut snapshot = self
            .snapshot
            .lock()
            .map_err(|_| AppError::State("snapshot lock poisoned".to_owned()))?;
        let target = snapshot
            .slot_mut(slot_id)
            .ok_or_else(|| AppError::UnknownSlot(slot_id.to_owned()))?;
        target.status = status;
        target.allocation = allocation;
        target.last_error = None;
        target.endpoint = Some(format!("liaison://{}", slot_id.to_ascii_lowercase()));
        snapshot.recalculate_pools();
        drop(snapshot);
        self.persist_snapshot();
        Ok(())
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
            return Err(AppError::Rejected(
                "too many workspace slots requested".to_owned(),
            ));
        }

        let allocations = balanced_workspace_allocations(active_ids.len(), capacity);
        let existing = self.snapshot()?;
        for slot in existing
            .slots
            .iter()
            .filter(|slot| slot.kind == SlotKind::Workspace)
        {
            if let Some(index) = active_ids
                .iter()
                .position(|id| id.eq_ignore_ascii_case(&slot.id))
            {
                let mut allocation = allocations[index];
                if slot.status != SlotStatus::Stopped {
                    allocation.gpu = slot.allocation.gpu;
                }
                if slot.status == SlotStatus::Stopped {
                    self.start_specific_slot(&slot.id, allocation, target_status)?;
                } else {
                    self.runtime.resize_slot(&slot.id, &allocation)?;
                    let mut snapshot = self
                        .snapshot
                        .lock()
                        .map_err(|_| AppError::State("snapshot lock poisoned".to_owned()))?;
                    let target = snapshot
                        .slot_mut(&slot.id)
                        .ok_or_else(|| AppError::UnknownSlot(slot.id.clone()))?;
                    target.status = target_status;
                    target.allocation = allocation;
                    target.last_error = None;
                }
            } else if slot.status != SlotStatus::Stopped {
                self.runtime.stop_slot(&slot.id)?;
                let mut snapshot = self
                    .snapshot
                    .lock()
                    .map_err(|_| AppError::State("snapshot lock poisoned".to_owned()))?;
                let target = snapshot
                    .slot_mut(&slot.id)
                    .ok_or_else(|| AppError::UnknownSlot(slot.id.clone()))?;
                target.status = SlotStatus::Stopped;
                target.allocation = ResourceAllocation::stopped();
                target.endpoint = None;
                target.last_error = None;
            }
        }

        let mut snapshot = self
            .snapshot
            .lock()
            .map_err(|_| AppError::State("snapshot lock poisoned".to_owned()))?;
        Self::sync_gpu_owner(&mut snapshot);
        snapshot.recalculate_pools();
        drop(snapshot);
        self.persist_snapshot();
        Ok(())
    }

    fn fit_active_workspaces_to_capacity(
        &self,
        capacity: PoolCapacity,
        target_status: SlotStatus,
    ) -> Result<(), AppError> {
        let existing = self.snapshot()?;
        let active: Vec<_> = existing
            .slots
            .iter()
            .filter(|slot| {
                slot.kind == SlotKind::Workspace && slot.status != SlotStatus::Stopped
            })
            .cloned()
            .collect();
        let total_cpu: u16 = active
            .iter()
            .map(|slot| slot.allocation.cpu_threads)
            .sum();
        let total_memory: u32 = active.iter().map(|slot| slot.allocation.memory_mib).sum();
        let needs_fit =
            total_cpu > capacity.cpu_threads || total_memory > capacity.memory_mib;
        let fitted = needs_fit
            .then(|| balanced_workspace_allocations(active.len(), capacity));

        for (index, slot) in active.iter().enumerate() {
            let mut allocation = fitted
                .as_ref()
                .map_or(slot.allocation, |values| values[index]);
            allocation.gpu = slot.allocation.gpu;
            if needs_fit {
                self.runtime.resize_slot(&slot.id, &allocation)?;
            }
            let mut snapshot = self
                .snapshot
                .lock()
                .map_err(|_| AppError::State("snapshot lock poisoned".to_owned()))?;
            let target = snapshot
                .slot_mut(&slot.id)
                .ok_or_else(|| AppError::UnknownSlot(slot.id.clone()))?;
            target.status = target_status;
            target.allocation = allocation;
            target.last_error = None;
        }
        Ok(())
    }

    fn validate_workspace_allocation(
        &self,
        snapshot: &SystemSnapshot,
        slot_id: &str,
        allocation: ResourceAllocation,
        capacity: PoolCapacity,
    ) -> Result<(), AppError> {
        if allocation.cpu_threads == 0 || allocation.memory_mib == 0 {
            return Err(AppError::Rejected(
                "CPU and memory allocations must be greater than zero".to_owned(),
            ));
        }
        if allocation.cpu_threads > capacity.cpu_threads
            || allocation.memory_mib > capacity.memory_mib
        {
            return Err(AppError::Rejected(
                "requested allocation exceeds the workspace pool".to_owned(),
            ));
        }
        let other_cpu: u16 = snapshot
            .slots
            .iter()
            .filter(|candidate| {
                candidate.kind == SlotKind::Workspace
                    && candidate.status != SlotStatus::Stopped
                    && !candidate.id.eq_ignore_ascii_case(slot_id)
            })
            .map(|candidate| candidate.allocation.cpu_threads)
            .sum();
        let other_memory: u32 = snapshot
            .slots
            .iter()
            .filter(|candidate| {
                candidate.kind == SlotKind::Workspace
                    && candidate.status != SlotStatus::Stopped
                    && !candidate.id.eq_ignore_ascii_case(slot_id)
            })
            .map(|candidate| candidate.allocation.memory_mib)
            .sum();

        let requested_cpu = other_cpu.saturating_add(allocation.cpu_threads);
        let requested_memory = other_memory.saturating_add(allocation.memory_mib);
        if requested_cpu > capacity.cpu_threads || requested_memory > capacity.memory_mib {
            return Err(AppError::Rejected(format!(
                "allocation would use {requested_cpu}/{} CPU threads and {requested_memory}/{} MiB memory",
                capacity.cpu_threads, capacity.memory_mib
            )));
        }
        Ok(())
    }

    fn workspace_capacity_for_mode(&self, mode: OperatingMode) -> PoolCapacity {
        match mode {
            OperatingMode::Class => self.config.class_workspace_pool,
            OperatingMode::Remote
            | OperatingMode::LocalExclusive
            | OperatingMode::Maintenance => self.config.workspace_pool,
        }
    }

    fn sync_workspace_pool_capacity(
        &self,
        snapshot: &mut SystemSnapshot,
        mode: OperatingMode,
    ) {
        let capacity = self.workspace_capacity_for_mode(mode);
        if let Some(pool) = snapshot.pools.iter_mut().find(|pool| pool.id == "workspace") {
            pool.cpu_capacity_threads = capacity.cpu_threads;
            pool.memory_capacity_mib = capacity.memory_mib;
        }
    }

    fn sync_gpu_owner(snapshot: &mut SystemSnapshot) {
        snapshot.gpu.reserved_by = snapshot
            .slots
            .iter()
            .find(|slot| {
                slot.status != SlotStatus::Stopped
                    && slot.allocation.gpu == GpuAccess::Exclusive
            })
            .map(|slot| slot.id.clone());
    }

    fn persist_snapshot(&self) {
        let Ok(snapshot) = self.snapshot() else {
            return;
        };
        let Ok(json) = serde_json::to_string_pretty(&snapshot) else {
            return;
        };
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
        config.data_directory = std::env::temp_dir()
            .join(format!("liaison-test-{}", liaison_core::unix_time_ms()))
            .display()
            .to_string();
        ServiceApp::new(config, Arc::new(MockRuntime::new())).unwrap()
    }

    #[test]
    fn custom_worker_allocations_are_preserved_and_capacity_checked() {
        let app = app();
        app.assign_worker(
            "W1",
            ResourceAllocation {
                cpu_threads: 10,
                memory_mib: 8_192,
                gpu: GpuAccess::None,
            },
        )
        .unwrap();
        app.assign_worker(
            "W2",
            ResourceAllocation {
                cpu_threads: 20,
                memory_mib: 16_384,
                gpu: GpuAccess::None,
            },
        )
        .unwrap();

        let snapshot = app.snapshot().unwrap();
        assert_eq!(snapshot.slot("W1").unwrap().allocation.cpu_threads, 10);
        assert_eq!(snapshot.slot("W2").unwrap().allocation.cpu_threads, 20);
        assert!(app
            .assign_worker(
                "W3",
                ResourceAllocation {
                    cpu_threads: 9,
                    memory_mib: 1_024,
                    gpu: GpuAccess::None,
                },
            )
            .is_err());
    }

    #[test]
    fn shared_gpu_can_be_used_by_multiple_workers() {
        let app = app();
        for id in ["W1", "W2"] {
            app.assign_worker(
                id,
                ResourceAllocation {
                    cpu_threads: 4,
                    memory_mib: 4_096,
                    gpu: GpuAccess::Shared,
                },
            )
            .unwrap();
        }
        let snapshot = app.snapshot().unwrap();
        assert_eq!(snapshot.slot("W1").unwrap().allocation.gpu, GpuAccess::Shared);
        assert_eq!(snapshot.slot("W2").unwrap().allocation.gpu, GpuAccess::Shared);
        assert!(snapshot.gpu.reserved_by.is_none());
    }

    #[test]
    fn exclusive_gpu_clears_shared_assignments() {
        let app = app();
        app.assign_worker(
            "W1",
            ResourceAllocation {
                cpu_threads: 4,
                memory_mib: 4_096,
                gpu: GpuAccess::Shared,
            },
        )
        .unwrap();
        app.assign_worker(
            "W2",
            ResourceAllocation {
                cpu_threads: 4,
                memory_mib: 4_096,
                gpu: GpuAccess::Exclusive,
            },
        )
        .unwrap();

        let snapshot = app.snapshot().unwrap();
        assert_eq!(snapshot.slot("W1").unwrap().allocation.gpu, GpuAccess::None);
        assert_eq!(
            snapshot.slot("W2").unwrap().allocation.gpu,
            GpuAccess::Exclusive
        );
        assert_eq!(snapshot.gpu.reserved_by.as_deref(), Some("W2"));
    }

    #[test]
    fn local_exclusive_keeps_persistent_slots_running() {
        let app = app();
        app.assign_worker(
            "W1",
            ResourceAllocation {
                cpu_threads: 8,
                memory_mib: 8_192,
                gpu: GpuAccess::None,
            },
        )
        .unwrap();
        app.set_mode(OperatingMode::LocalExclusive).unwrap();
        let snapshot = app.snapshot().unwrap();
        assert!(snapshot
            .slots
            .iter()
            .filter(|slot| slot.kind == SlotKind::Workspace)
            .all(|slot| slot.status == SlotStatus::Stopped));
        assert!(snapshot
            .slots
            .iter()
            .filter(|slot| slot.kind == SlotKind::Persistent)
            .all(|slot| slot.status == SlotStatus::Running));
    }
}
