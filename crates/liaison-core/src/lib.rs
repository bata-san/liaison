use serde::{Deserialize, Serialize};

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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ResourceAllocation {
    pub cpu_threads: u16,
    pub memory_mib: u32,
    pub gpu: GpuAccess,
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
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct GpuMetrics {
    pub utilization_percent: f32,
    pub memory_used_mib: u32,
    pub memory_total_mib: u32,
    pub reserved_by: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SystemSnapshot {
    pub mode: OperatingMode,
    pub tailscale_online: bool,
    pub host: HostMetrics,
    pub gpu: GpuMetrics,
    pub pools: Vec<ResourcePoolSummary>,
    pub slots: Vec<SlotSummary>,
    pub updated_at_unix_ms: u64,
}

impl SystemSnapshot {
    pub fn demo() -> Self {
        Self {
            mode: OperatingMode::Remote,
            tailscale_online: true,
            host: HostMetrics {
                cpu_percent: 31.0,
                memory_used_mib: 27_648,
                memory_total_mib: 65_536,
            },
            gpu: GpuMetrics {
                utilization_percent: 58.0,
                memory_used_mib: 18_432,
                memory_total_mib: 49_152,
                reserved_by: Some("W1".into()),
            },
            pools: vec![
                ResourcePoolSummary {
                    id: "persistent".into(),
                    cpu_capacity_threads: 6,
                    memory_capacity_mib: 8_192,
                    cpu_allocated_threads: 4,
                    memory_allocated_mib: 6_144,
                },
                ResourcePoolSummary {
                    id: "workspace".into(),
                    cpu_capacity_threads: 38,
                    memory_capacity_mib: 40_960,
                    cpu_allocated_threads: 24,
                    memory_allocated_mib: 24_576,
                },
            ],
            slots: vec![
                slot("P1", SlotKind::Persistent, SlotStatus::Running, 2, 3_072, GpuAccess::None, 8.0, 1_804),
                slot("P2", SlotKind::Persistent, SlotStatus::Running, 2, 3_072, GpuAccess::None, 5.0, 1_223),
                slot("W1", SlotKind::Workspace, SlotStatus::Running, 12, 12_288, GpuAccess::Exclusive, 72.0, 9_742),
                slot("W2", SlotKind::Workspace, SlotStatus::Running, 8, 8_192, GpuAccess::None, 34.0, 5_314),
                slot("W3", SlotKind::Workspace, SlotStatus::Throttled, 4, 4_096, GpuAccess::None, 12.0, 2_011),
                slot("W4", SlotKind::Workspace, SlotStatus::Stopped, 0, 0, GpuAccess::None, 0.0, 0),
                slot("W5", SlotKind::Workspace, SlotStatus::Stopped, 0, 0, GpuAccess::None, 0.0, 0),
            ],
            updated_at_unix_ms: 0,
        }
    }
}

fn slot(
    id: &str,
    kind: SlotKind,
    status: SlotStatus,
    cpu_threads: u16,
    memory_mib: u32,
    gpu: GpuAccess,
    cpu_percent: f32,
    memory_used_mib: u32,
) -> SlotSummary {
    SlotSummary {
        id: id.into(),
        kind,
        status,
        owner: None,
        allocation: ResourceAllocation {
            cpu_threads,
            memory_mib,
            gpu,
        },
        cpu_percent,
        memory_used_mib,
    }
}
