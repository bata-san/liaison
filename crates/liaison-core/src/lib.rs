use std::{
    fs, io,
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};

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
        Self {
            cpu_threads: 0,
            memory_mib: 0,
            gpu: GpuAccess::None,
        }
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
        Self {
            cpu_percent: 0.0,
            memory_used_mib: 0,
            memory_total_mib: 65_536,
        }
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
    pub auto_tuned: bool,
    pub host_cpu_threads: u16,
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
            auto_tuned: config.auto_tune,
            host_cpu_threads: detected_cpu_threads(),
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
        self.slots
            .iter()
            .find(|slot| slot.id.eq_ignore_ascii_case(id))
    }

    pub fn slot_mut(&mut self, id: &str) -> Option<&mut SlotSummary> {
        self.slots
            .iter_mut()
            .find(|slot| slot.id.eq_ignore_ascii_case(id))
    }

    pub fn recalculate_pools(&mut self) {
        for pool in &mut self.pools {
            let kind = if pool.id == "persistent" {
                SlotKind::Persistent
            } else {
                SlotKind::Workspace
            };
            pool.cpu_allocated_threads = self
                .slots
                .iter()
                .filter(|slot| slot.kind == kind && slot.status != SlotStatus::Stopped)
                .map(|slot| slot.allocation.cpu_threads)
                .sum();
            pool.memory_allocated_mib = self
                .slots
                .iter()
                .filter(|slot| slot.kind == kind && slot.status != SlotStatus::Stopped)
                .map(|slot| slot.allocation.memory_mib)
                .sum();
        }
        self.updated_at_unix_ms = unix_time_ms();
    }

    pub fn set_gpu_reservation(
        &mut self,
        slot_id: Option<&str>,
        access: GpuAccess,
    ) -> Result<(), CoreError> {
        for slot in &mut self.slots {
            slot.allocation.gpu = GpuAccess::None;
        }
        self.gpu.reserved_by = None;
        if let Some(id) = slot_id {
            let reserved_id = {
                let slot = self
                    .slot_mut(id)
                    .ok_or_else(|| CoreError::UnknownSlot(id.to_owned()))?;
                if slot.kind != SlotKind::Workspace {
                    return Err(CoreError::InvalidOperation(
                        "GPU can only be reserved by a workspace slot".to_owned(),
                    ));
                }
                if slot.status == SlotStatus::Stopped {
                    return Err(CoreError::InvalidOperation(
                        "GPU cannot be reserved by a stopped slot".to_owned(),
                    ));
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
    #[serde(default = "default_auto_tune")]
    pub auto_tune: bool,
    #[serde(default = "default_cpu_reserve_percent")]
    pub host_cpu_reserve_percent: u8,
    #[serde(default = "default_memory_reserve_percent")]
    pub host_memory_reserve_percent: u8,
    #[serde(default = "default_minimum_host_memory_mib")]
    pub minimum_host_memory_mib: u32,
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
            persistent_pool: PoolCapacity {
                cpu_threads: 6,
                memory_mib: 8_192,
            },
            workspace_pool: PoolCapacity {
                cpu_threads: 38,
                memory_mib: 40_960,
            },
            class_workspace_pool: PoolCapacity {
                cpu_threads: 12,
                memory_mib: 16_384,
            },
            max_workspace_slots: 5,
            persistent_autostart: true,
            metrics_interval_ms: 2_000,
            auto_tune: default_auto_tune(),
            host_cpu_reserve_percent: default_cpu_reserve_percent(),
            host_memory_reserve_percent: default_memory_reserve_percent(),
            minimum_host_memory_mib: default_minimum_host_memory_mib(),
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

    pub fn tune_for_host(&mut self, host_cpu_threads: u16, host_memory_mib: u32) {
        if !self.auto_tune {
            return;
        }

        let host_cpu_threads = host_cpu_threads.max(1);
        let host_memory_mib = host_memory_mib.max(1_024);

        let cpu_reserve = percent_ceil_u16(host_cpu_threads, self.host_cpu_reserve_percent)
            .max(1)
            .min(host_cpu_threads.saturating_sub(1));
        let managed_cpu = host_cpu_threads.saturating_sub(cpu_reserve).max(1);

        let percentage_memory_reserve =
            percent_ceil_u32(host_memory_mib, self.host_memory_reserve_percent);
        let maximum_memory_reserve = host_memory_mib.saturating_sub(1_024);
        let memory_reserve = self
            .minimum_host_memory_mib
            .max(percentage_memory_reserve)
            .min(maximum_memory_reserve);
        let managed_memory = host_memory_mib.saturating_sub(memory_reserve).max(1_024);

        let persistent_supported = managed_cpu >= 4 && managed_memory >= 4_096;
        let persistent_cpu = if persistent_supported {
            percent_ceil_u16(managed_cpu, 20)
                .max(2)
                .min(managed_cpu.saturating_sub(1))
        } else {
            0
        };
        let persistent_memory = if persistent_supported {
            round_down_512(percent_ceil_u32(managed_memory, 20).max(2_048))
                .min(managed_memory.saturating_sub(1_024))
        } else {
            0
        };

        self.persistent_autostart &= persistent_supported;
        self.persistent_pool = PoolCapacity {
            cpu_threads: persistent_cpu,
            memory_mib: persistent_memory,
        };
        self.workspace_pool = PoolCapacity {
            cpu_threads: managed_cpu.saturating_sub(persistent_cpu).max(1),
            memory_mib: managed_memory
                .saturating_sub(persistent_memory)
                .max(1_024),
        };
        self.class_workspace_pool = PoolCapacity {
            cpu_threads: percent_ceil_u16(self.workspace_pool.cpu_threads, 35)
                .max(1)
                .min(self.workspace_pool.cpu_threads),
            memory_mib: round_down_512(
                percent_ceil_u32(self.workspace_pool.memory_mib, 40).max(1_024),
            )
            .max(512)
            .min(self.workspace_pool.memory_mib),
        };

        let cpu_slot_limit = usize::from(self.workspace_pool.cpu_threads.max(1));
        let memory_slot_limit = (self.workspace_pool.memory_mib / 512).max(1) as usize;
        self.max_workspace_slots = cpu_slot_limit
            .min(memory_slot_limit)
            .min(5)
            .max(1) as u8;
    }

    pub fn validate(&self) -> Result<(), ConfigError> {
        if !self.listen_address.starts_with("127.0.0.1:")
            && !self.listen_address.starts_with("[::1]:")
        {
            return Err(ConfigError::Validation(
                "listen_address must be loopback-only".to_owned(),
            ));
        }
        if self.auth_token.len() < 16 {
            return Err(ConfigError::Validation(
                "auth_token must contain at least 16 characters".to_owned(),
            ));
        }
        if !(1..=5).contains(&self.max_workspace_slots) {
            return Err(ConfigError::Validation(
                "max_workspace_slots must be between 1 and 5".to_owned(),
            ));
        }
        if self.host_cpu_reserve_percent > 80 || self.host_memory_reserve_percent > 80 {
            return Err(ConfigError::Validation(
                "host reserve percentages must be between 0 and 80".to_owned(),
            ));
        }
        if self.class_workspace_pool.cpu_threads > self.workspace_pool.cpu_threads
            || self.class_workspace_pool.memory_mib > self.workspace_pool.memory_mib
        {
            return Err(ConfigError::Validation(
                "class workspace pool cannot exceed remote workspace pool".to_owned(),
            ));
        }
        Ok(())
    }
}

pub fn balanced_workspace_allocations(
    active_slots: usize,
    capacity: PoolCapacity,
) -> Vec<ResourceAllocation> {
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
        ResourceAllocation {
            cpu_threads: cpu_first,
            memory_mib: mem_first,
            gpu: GpuAccess::None,
        },
        ResourceAllocation {
            cpu_threads: cpu_second,
            memory_mib: mem_second,
            gpu: GpuAccess::None,
        },
    ]
}

pub fn detected_cpu_threads() -> u16 {
    std::thread::available_parallelism()
        .map(|value| value.get())
        .unwrap_or(1)
        .try_into()
        .unwrap_or(u16::MAX)
}

pub fn unix_time_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

const fn default_auto_tune() -> bool {
    true
}

const fn default_cpu_reserve_percent() -> u8 {
    15
}

const fn default_memory_reserve_percent() -> u8 {
    20
}

const fn default_minimum_host_memory_mib() -> u32 {
    2_048
}

fn percent_ceil_u16(value: u16, percent: u8) -> u16 {
    ((u32::from(value) * u32::from(percent) + 99) / 100)
        .try_into()
        .unwrap_or(u16::MAX)
}

fn percent_ceil_u32(value: u32, percent: u8) -> u32 {
    value
        .saturating_mul(u32::from(percent))
        .saturating_add(99)
        / 100
}

fn round_down_512(value: u32) -> u32 {
    value / 512 * 512
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
        let allocations = balanced_workspace_allocations(
            5,
            PoolCapacity {
                cpu_threads: 38,
                memory_mib: 40_960,
            },
        );
        assert_eq!(allocations.len(), 5);
        assert_eq!(
            allocations
                .iter()
                .map(|allocation| allocation.cpu_threads)
                .sum::<u16>(),
            38
        );
        assert_eq!(
            allocations
                .iter()
                .map(|allocation| allocation.memory_mib)
                .sum::<u32>(),
            40_960
        );
        assert!(allocations
            .iter()
            .all(|allocation| allocation.cpu_threads >= 7));
    }

    #[test]
    fn zero_active_slots_has_no_allocations() {
        assert!(balanced_workspace_allocations(
            0,
            PoolCapacity {
                cpu_threads: 38,
                memory_mib: 40_960,
            },
        )
        .is_empty());
    }

    #[test]
    fn only_running_workspace_can_reserve_gpu() {
        let config = AppConfig::default();
        let mut snapshot = SystemSnapshot::new(&config);
        assert!(snapshot
            .set_gpu_reservation(Some("W1"), GpuAccess::Exclusive)
            .is_err());
        snapshot.slot_mut("W1").unwrap().status = SlotStatus::Running;
        snapshot
            .set_gpu_reservation(Some("W1"), GpuAccess::Exclusive)
            .unwrap();
        assert_eq!(snapshot.gpu.reserved_by.as_deref(), Some("W1"));
        assert_eq!(
            snapshot.slot("W1").unwrap().allocation.gpu,
            GpuAccess::Exclusive
        );
    }

    #[test]
    fn production_config_must_bind_to_loopback() {
        let mut config = AppConfig::default();
        config.listen_address = "0.0.0.0:57841".to_owned();
        assert!(config.validate().is_err());
    }

    #[test]
    fn auto_tune_scales_down_for_small_machines() {
        let mut config = AppConfig::default();
        config.tune_for_host(4, 8_192);
        assert!(config.workspace_pool.cpu_threads >= 1);
        assert!(config.workspace_pool.memory_mib >= 1_024);
        assert!(config.persistent_pool.cpu_threads <= 2);
        assert!(config.max_workspace_slots <= 5);
    }

    #[test]
    fn auto_tune_preserves_host_headroom_on_large_machines() {
        let mut config = AppConfig::default();
        config.tune_for_host(64, 131_072);
        let managed_cpu = config
            .persistent_pool
            .cpu_threads
            .saturating_add(config.workspace_pool.cpu_threads);
        let managed_memory = config
            .persistent_pool
            .memory_mib
            .saturating_add(config.workspace_pool.memory_mib);
        assert!(managed_cpu < 64);
        assert!(managed_memory < 131_072);
        assert_eq!(config.max_workspace_slots, 5);
    }

    #[test]
    fn explicit_capacity_is_kept_when_auto_tune_is_disabled() {
        let mut config = AppConfig::default();
        config.auto_tune = false;
        let original = config.clone();
        config.tune_for_host(2, 2_048);
        assert_eq!(config, original);
    }
}
