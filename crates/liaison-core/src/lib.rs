use std::{fs, io, path::Path, time::{SystemTime, UNIX_EPOCH}};

use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum OperatingMode {
    #[default]
    Remote,
    Class,
    LocalExclusive,
    Maintenance,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SlotKind {
    Persistent,
    Workspace,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SlotStatus {
    Stopped,
    Starting,
    Running,
    Throttled,
    Draining,
    Error,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum GpuAccess {
    None,
    Shared,
    Exclusive,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "kebab-case")]
pub enum RuntimeKind {
    #[default]
    Mock,
    WslDocker,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub struct ResourceAllocation {
    pub cpu_threads: u16,
    pub memory_mib: u32,
    pub gpu: GpuAccess,
}

impl ResourceAllocation {
    pub const fn stopped() -> Self {
        Self { cpu_threads: 0, memory_mib: 0, gpu: GpuAccess::None }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SlotSummary {
    pub id: String,
    pub kind: SlotKind,
    pub status: SlotStatus,
    pub owner: Option<String>,
    pub allocation: ResourceAllocation,
    pub cpu_percent: f32,
    pub memory_used_mib: u32,
    pub endpoint: Option<String>,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ResourcePoolSummary {
    pub id: String,
    pub cpu_capacity_threads: u16,
    pub memory_capacity_mib: u32,
    pub cpu_allocated_threads: u16,
    pub memory_allocated_mib: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HostMetrics {
    pub cpu_percent: f32,
    pub memory_used_mib: u32,
    pub memory_total_mib: u32,
}

impl Default for HostMetrics {
    fn default() -> Self {
        Self { cpu_percent: 0.0, memory_used_mib: 0, memory_total_mib: 65_536 }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct GpuMetrics {
    pub utilization_percent: f32,
    pub memory_used_mib: u32,
    pub memory_total_mib: u32,
    pub reserved_by: Option<String>,
    pub available: bool,
}

impl Default for GpuMetrics {
    fn default() -> Self {
        Self {
            utilization_percent: 0.0,
            memory_used_mib: 0,
            memory_total_mib: 0,
            reserved_by: None,
            available: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SystemSnapshot {
    pub service_version: String,
    pub mode: OperatingMode,
    pub runtime: RuntimeKind,
    pub service_online: bool,
    pub tailscale_online: bool,
    pub host: HostMetrics,
    pub gpu: GpuMetrics,
    pub pools: Vec<ResourcePoolSummary>,
    pub slots: Vec<SlotSummary>,
    pub updated_at_unix_ms: u64,
}

impl SystemSnapshot {
    pub fn new(config: &AppConfig) -> Self {
        let mut slots = Vec::with_capacity(7);
        for index in 1..=2 {
            slots.push(SlotSummary {
                id: format!("P{index}"),
                kind: SlotKind::Persistent,
                status: SlotStatus::Stopped,
                owner: None,
                allocation: ResourceAllocation::stopped(),
                cpu_percent: 0.0,
                memory_used_mib: 0,
                endpoint: None,
                last_error: None,
            });
        }
        for index in 1..=config.max_workspace_slots {
            slots.push(SlotSummary {
                id: format!("W{index}"),
                kind: SlotKind::Workspace,
                status: SlotStatus::Stopped,
                owner: None,
                allocation: ResourceAllocation::stopped(),
                cpu_percent: 0.0,
                memory_used_mib: 0,
                endpoint: None,
                last_error: None,
            });
        }
        let mut snapshot = Self {
            service_version: env!("CARGO_PKG_VERSION").to_owned(),
            mode: OperatingMode::Remote,
            runtime: config.runtime,
            service_online: true,
            tailscale_online: false,
            host: HostMetrics::default(),
            gpu: GpuMetrics::default(),
            pools: vec![
                ResourcePoolSummary {
                    id: "persistent".to_owned(),
                    cpu_capacity_threads: config.persistent_pool.cpu_threads,
                    memory_capacity_mib: config.persistent_pool.memory_mib,
                    cpu_allocated_threads: 0,
                    memory_allocated_mib: 0,
                },
                ResourcePoolSummary {
                    id: "workspace".to_owned(),
                    cpu_capacity_threads: config.workspace_pool.cpu_threads,
                    memory_capacity_mib: config.workspace_pool.memory_mib,
                    cpu_allocated_threads: 0,
                    memory_allocated_mib: 0,
                },
            ],
            slots,
            updated_at_unix_ms: unix_time_ms(),
        };
        snapshot.recalculate_pools();
        snapshot
    }

    pub fn slot(&self, id: &str) -> Option<&SlotSummary> {
        self.slots.iter().find(|slot| slot.id.eq_ignore_ascii_case(id))
    }

    pub fn slot_mut(&mut self, id: &str) -> Option<&mut SlotSummary> {
        self.slots.iter_mut().find(|slot| slot.id.eq_ignore_ascii_case(id))
    }

    pub fn recalculate_pools(&mut self) {
        for pool in &mut self.pools {
            let kind = if pool.id == "persistent" { SlotKind::Persistent } else { SlotKind::Workspace };
            pool.cpu_allocated_threads = self.slots.iter()
                .filter(|slot| slot.kind == kind && slot.status != SlotStatus::Stopped)
                .map(|slot| slot.allocation.cpu_threads)
                .sum();
            pool.memory_allocated_mib = self.slots.iter()
                .filter(|slot| slot.kind == kind && slot.status != SlotStatus::Stopped)
                .map(|slot| slot.allocation.memory_mib)
                .sum();
        }
        self.updated_at_unix_ms = unix_time_ms();
    }

    pub fn set_gpu_reservation(&mut self, slot_id: Option<&str>, access: GpuAccess) -> Result<(), CoreError> {
        for slot in &mut self.slots {
            slot.allocation.gpu = GpuAccess::None;
        }
        self.gpu.reserved_by = None;
        if let Some(id) = slot_id {
            let reserved_id = {
                let slot = self.slot_mut(id).ok_or_else(|| CoreError::UnknownSlot(id.to_owned()))?;
                if slot.kind != SlotKind::Workspace {
                    return Err(CoreError::InvalidOperation("GPU can only be reserved by a workspace slot".to_owned()));
                }
                if slot.status == SlotStatus::Stopped {
                    return Err(CoreError::InvalidOperation("GPU cannot be reserved by a stopped slot".to_owned()));
                }
                slot.allocation.gpu = access;
                slot.id.clone()
            };
            self.gpu.reserved_by = Some(reserved_id);
        }
        self.updated_at_unix_ms = unix_time_ms();
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub struct PoolCapacity {
    pub cpu_threads: u16,
    pub memory_mib: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AppConfig {
    pub listen_address: String,
    pub auth_token: String,
    pub runtime: RuntimeKind,
    pub wsl_distribution: String,
    pub workspace_image: String,
    pub persistent_image: String,
    pub data_directory: String,
    pub persistent_pool: PoolCapacity,
    pub workspace_pool: PoolCapacity,
    pub class_workspace_pool: PoolCapacity,
    pub max_workspace_slots: u8,
    pub persistent_autostart: bool,
    pub metrics_interval_ms: u64,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            listen_address: "127.0.0.1:57841".to_owned(),
            auth_token: "change-this-token-before-production".to_owned(),
            runtime: RuntimeKind::Mock,
            wsl_distribution: "LiaisonRuntime".to_owned(),
            workspace_image: "ubuntu:24.04".to_owned(),
            persistent_image: "ubuntu:24.04".to_owned(),
            data_directory: "runtime-data".to_owned(),
            persistent_pool: PoolCapacity { cpu_threads: 6, memory_mib: 8_192 },
            workspace_pool: PoolCapacity { cpu_threads: 38, memory_mib: 40_960 },
            class_workspace_pool: PoolCapacity { cpu_threads: 12, memory_mib: 16_384 },
            max_workspace_slots: 5,
            persistent_autostart: true,
            metrics_interval_ms: 2_000,
        }
    }
}

impl AppConfig {
    pub fn load_or_create(path: &Path) -> Result<Self, ConfigError> {
        if path.exists() {
            let text = fs::read_to_string(path)?;
            let config: Self = serde_json::from_str(&text)?;
            config.validate()?;
            Ok(config)
        } else {
            let config = Self::default();
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::write(path, serde_json::to_string_pretty(&config)?)?;
            Ok(config)
        }
    }

    pub fn validate(&self) -> Result<(), ConfigError> {
        if !self.listen_address.starts_with("127.0.0.1:") && !self.listen_address.starts_with("[::1]:") {
            return Err(ConfigError::Validation("listen_address must be loopback-only".to_owned()));
        }
        if self.auth_token.len() < 16 {
            return Err(ConfigError::Validation("auth_token must contain at least 16 characters".to_owned()));
        }
        if !(1..=5).contains(&self.max_workspace_slots) {
            return Err(ConfigError::Validation("max_workspace_slots must be between 1 and 5".to_owned()));
        }
        if self.class_workspace_pool.cpu_threads > self.workspace_pool.cpu_threads
            || self.class_workspace_pool.memory_mib > self.workspace_pool.memory_mib
        {
            return Err(ConfigError::Validation("class workspace pool cannot exceed remote workspace pool".to_owned()));
        }
        Ok(())
    }
}

pub fn balanced_workspace_allocations(active_slots: usize, capacity: PoolCapacity) -> Vec<ResourceAllocation> {
    if active_slots == 0 {
        return Vec::new();
    }
    let count = active_slots as u16;
    let base_cpu = capacity.cpu_threads / count;
    let cpu_remainder = capacity.cpu_threads % count;
    let base_memory = capacity.memory_mib / active_slots as u32;
    let memory_remainder = capacity.memory_mib % active_slots as u32;
    (0..active_slots)
        .map(|index| ResourceAllocation {
            cpu_threads: base_cpu + u16::from((index as u16) < cpu_remainder),
            memory_mib: base_memory + u32::from((index as u32) < memory_remainder),
            gpu: GpuAccess::None,
        })
        .collect()
}

pub fn balanced_persistent_allocations(capacity: PoolCapacity) -> [ResourceAllocation; 2] {
    let cpu_first = capacity.cpu_threads / 2 + capacity.cpu_threads % 2;
    let cpu_second = capacity.cpu_threads / 2;
    let mem_first = capacity.memory_mib / 2 + capacity.memory_mib % 2;
    let mem_second = capacity.memory_mib / 2;
    [
        ResourceAllocation { cpu_threads: cpu_first, memory_mib: mem_first, gpu: GpuAccess::None },
        ResourceAllocation { cpu_threads: cpu_second, memory_mib: mem_second, gpu: GpuAccess::None },
    ]
}

pub fn unix_time_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("unknown slot: {0}")]
    UnknownSlot(String),
    #[error("invalid operation: {0}")]
    InvalidOperation(String),
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("I/O error: {0}")]
    Io(#[from] io::Error),
    #[error("invalid JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("invalid configuration: {0}")]
    Validation(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workspace_pool_is_split_without_losing_capacity() {
        let allocations = balanced_workspace_allocations(5, PoolCapacity { cpu_threads: 38, memory_mib: 40_960 });
        assert_eq!(allocations.len(), 5);
        assert_eq!(allocations.iter().map(|a| a.cpu_threads).sum::<u16>(), 38);
        assert_eq!(allocations.iter().map(|a| a.memory_mib).sum::<u32>(), 40_960);
        assert!(allocations.iter().all(|a| a.cpu_threads >= 7));
    }

    #[test]
    fn zero_active_slots_has_no_allocations() {
        assert!(balanced_workspace_allocations(0, PoolCapacity { cpu_threads: 38, memory_mib: 40_960 }).is_empty());
    }

    #[test]
    fn only_running_workspace_can_reserve_gpu() {
        let config = AppConfig::default();
        let mut snapshot = SystemSnapshot::new(&config);
        assert!(snapshot.set_gpu_reservation(Some("W1"), GpuAccess::Exclusive).is_err());
        snapshot.slot_mut("W1").unwrap().status = SlotStatus::Running;
        snapshot.set_gpu_reservation(Some("W1"), GpuAccess::Exclusive).unwrap();
        assert_eq!(snapshot.gpu.reserved_by.as_deref(), Some("W1"));
        assert_eq!(snapshot.slot("W1").unwrap().allocation.gpu, GpuAccess::Exclusive);
    }

    #[test]
    fn production_config_must_bind_to_loopback() {
        let mut config = AppConfig::default();
        config.listen_address = "0.0.0.0:57841".to_owned();
        assert!(config.validate().is_err());
    }
}
