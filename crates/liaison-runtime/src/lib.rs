use std::{
    collections::HashMap,
    process::{Command, Output},
    sync::Mutex,
};

use liaison_core::{
    GpuAccess, GpuMetrics, HostMetrics, ResourceAllocation, RuntimeKind, SlotKind, SlotSummary,
    SlotStatus,
};
use sysinfo::System;
use thiserror::Error;

pub trait RuntimeAdapter: Send + Sync {
    fn kind(&self) -> RuntimeKind;
    fn start_slot(&self, slot: &SlotSummary) -> Result<(), RuntimeError>;
    fn stop_slot(&self, slot_id: &str) -> Result<(), RuntimeError>;
    fn resize_slot(&self, slot_id: &str, allocation: &ResourceAllocation) -> Result<(), RuntimeError>;
    fn set_gpu_access(&self, slot: &SlotSummary, access: GpuAccess) -> Result<(), RuntimeError>;
    fn collect_host_metrics(&self) -> HostMetrics;
    fn collect_gpu_metrics(&self) -> GpuMetrics;
    fn tailscale_online(&self) -> bool;
}

#[derive(Debug, Default)]
pub struct MockRuntime {
    slots: Mutex<HashMap<String, ResourceAllocation>>,
    gpu_owner: Mutex<Option<String>>,
}

impl MockRuntime {
    pub fn new() -> Self {
        Self::default()
    }
}

impl RuntimeAdapter for MockRuntime {
    fn kind(&self) -> RuntimeKind {
        RuntimeKind::Mock
    }

    fn start_slot(&self, slot: &SlotSummary) -> Result<(), RuntimeError> {
        self.slots
            .lock()
            .map_err(|_| RuntimeError::State("mock runtime lock poisoned".to_owned()))?
            .insert(slot.id.clone(), slot.allocation.clone());
        Ok(())
    }

    fn stop_slot(&self, slot_id: &str) -> Result<(), RuntimeError> {
        self.slots
            .lock()
            .map_err(|_| RuntimeError::State("mock runtime lock poisoned".to_owned()))?
            .remove(slot_id);
        let mut gpu_owner = self.gpu_owner
            .lock()
            .map_err(|_| RuntimeError::State("mock GPU lock poisoned".to_owned()))?;
        if gpu_owner.as_deref() == Some(slot_id) {
            *gpu_owner = None;
        }
        Ok(())
    }

    fn resize_slot(&self, slot_id: &str, allocation: &ResourceAllocation) -> Result<(), RuntimeError> {
        let mut slots = self.slots
            .lock()
            .map_err(|_| RuntimeError::State("mock runtime lock poisoned".to_owned()))?;
        if !slots.contains_key(slot_id) {
            return Err(RuntimeError::NotFound(slot_id.to_owned()));
        }
        slots.insert(slot_id.to_owned(), allocation.clone());
        Ok(())
    }

    fn set_gpu_access(&self, slot: &SlotSummary, access: GpuAccess) -> Result<(), RuntimeError> {
        let slot_id = &slot.id;
        let slots = self.slots
            .lock()
            .map_err(|_| RuntimeError::State("mock runtime lock poisoned".to_owned()))?;
        if !slots.contains_key(slot_id) {
            return Err(RuntimeError::NotFound(slot_id.to_owned()));
        }
        drop(slots);
        let mut owner = self.gpu_owner
            .lock()
            .map_err(|_| RuntimeError::State("mock GPU lock poisoned".to_owned()))?;
        match access {
            GpuAccess::None => {
                if owner.as_deref() == Some(slot_id.as_str()) {
                    *owner = None;
                }
            }
            GpuAccess::Shared | GpuAccess::Exclusive => *owner = Some(slot_id.to_owned()),
        }
        Ok(())
    }

    fn collect_host_metrics(&self) -> HostMetrics {
        let slots = self.slots.lock().ok();
        let active = slots.as_ref().map_or(0, |slots| slots.len()) as f32;
        let memory = slots.as_ref().map_or(0, |slots| {
            slots.values().map(|value| value.memory_mib / 3).sum()
        });
        HostMetrics {
            cpu_percent: (7.0 + active * 11.0).min(92.0),
            memory_used_mib: 12_288 + memory,
            memory_total_mib: 65_536,
        }
    }

    fn collect_gpu_metrics(&self) -> GpuMetrics {
        let owner = self.gpu_owner.lock().ok().and_then(|owner| owner.clone());
        GpuMetrics {
            utilization_percent: if owner.is_some() { 47.0 } else { 2.0 },
            memory_used_mib: if owner.is_some() { 12_288 } else { 768 },
            memory_total_mib: 49_152,
            reserved_by: owner,
            available: true,
        }
    }

    fn tailscale_online(&self) -> bool {
        true
    }
}

#[derive(Debug, Clone)]
pub struct WslDockerRuntime {
    distribution: String,
    workspace_image: String,
    persistent_image: String,
}

impl WslDockerRuntime {
    pub fn new(
        distribution: impl Into<String>,
        workspace_image: impl Into<String>,
        persistent_image: impl Into<String>,
    ) -> Self {
        Self {
            distribution: distribution.into(),
            workspace_image: workspace_image.into(),
            persistent_image: persistent_image.into(),
        }
    }

    fn container_name(slot_id: &str) -> String {
        format!("liaison-{}", slot_id.to_ascii_lowercase())
    }

    fn image_for(&self, kind: SlotKind) -> &str {
        match kind {
            SlotKind::Persistent => &self.persistent_image,
            SlotKind::Workspace => &self.workspace_image,
        }
    }

    fn run_wsl(&self, arguments: &[String]) -> Result<Output, RuntimeError> {
        let output = Command::new("wsl.exe")
            .arg("-d")
            .arg(&self.distribution)
            .arg("--")
            .args(arguments)
            .output()
            .map_err(RuntimeError::Io)?;
        if output.status.success() {
            Ok(output)
        } else {
            Err(RuntimeError::Command {
                program: "wsl.exe".to_owned(),
                message: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
            })
        }
    }

    fn docker(&self, arguments: Vec<String>) -> Result<Output, RuntimeError> {
        let mut command = vec!["docker".to_owned()];
        command.extend(arguments);
        self.run_wsl(&command)
    }

    fn exists(&self, slot_id: &str) -> bool {
        self.docker(vec![
            "container".to_owned(),
            "inspect".to_owned(),
            Self::container_name(slot_id),
        ]).is_ok()
    }
}

impl RuntimeAdapter for WslDockerRuntime {
    fn kind(&self) -> RuntimeKind {
        RuntimeKind::WslDocker
    }

    fn start_slot(&self, slot: &SlotSummary) -> Result<(), RuntimeError> {
        let name = Self::container_name(&slot.id);
        if self.exists(&slot.id) {
            self.docker(vec!["start".to_owned(), name])?;
            return self.resize_slot(&slot.id, &slot.allocation);
        }

        let volume = format!("liaison_{}_data", slot.id.to_ascii_lowercase());
        let mut args = vec![
            "run".to_owned(),
            "--detach".to_owned(),
            "--name".to_owned(),
            name,
            "--restart".to_owned(),
            if slot.kind == SlotKind::Persistent { "unless-stopped" } else { "no" }.to_owned(),
            "--cpus".to_owned(),
            slot.allocation.cpu_threads.to_string(),
            "--memory".to_owned(),
            format!("{}m", slot.allocation.memory_mib),
            "--label".to_owned(),
            format!("liaison.slot={}", slot.id),
            "--volume".to_owned(),
            format!("{volume}:/workspace"),
        ];
        if slot.allocation.gpu != GpuAccess::None {
            args.extend(["--gpus".to_owned(), "all".to_owned()]);
        }
        args.extend([
            self.image_for(slot.kind).to_owned(),
            "sh".to_owned(),
            "-lc".to_owned(),
            "trap : TERM INT; sleep infinity & wait".to_owned(),
        ]);
        self.docker(args)?;
        Ok(())
    }

    fn stop_slot(&self, slot_id: &str) -> Result<(), RuntimeError> {
        if !self.exists(slot_id) {
            return Ok(());
        }
        self.docker(vec![
            "stop".to_owned(),
            "--time".to_owned(),
            "20".to_owned(),
            Self::container_name(slot_id),
        ])?;
        Ok(())
    }

    fn resize_slot(&self, slot_id: &str, allocation: &ResourceAllocation) -> Result<(), RuntimeError> {
        if !self.exists(slot_id) {
            return Err(RuntimeError::NotFound(slot_id.to_owned()));
        }
        self.docker(vec![
            "update".to_owned(),
            "--cpus".to_owned(),
            allocation.cpu_threads.to_string(),
            "--memory".to_owned(),
            format!("{}m", allocation.memory_mib),
            Self::container_name(slot_id),
        ])?;
        Ok(())
    }

    fn set_gpu_access(&self, slot: &SlotSummary, access: GpuAccess) -> Result<(), RuntimeError> {
        let name = Self::container_name(&slot.id);
        if self.exists(&slot.id) {
            let _ = self.docker(vec!["stop".to_owned(), "--time".to_owned(), "20".to_owned(), name.clone()]);
            self.docker(vec!["rm".to_owned(), name])?;
        }
        let mut updated = slot.clone();
        updated.allocation.gpu = access;
        self.start_slot(&updated)
    }

    fn collect_host_metrics(&self) -> HostMetrics {
        let mut system = System::new_all();
        system.refresh_all();
        HostMetrics {
            cpu_percent: system.global_cpu_usage(),
            memory_used_mib: bytes_to_mib(system.used_memory()),
            memory_total_mib: bytes_to_mib(system.total_memory()),
        }
    }

    fn collect_gpu_metrics(&self) -> GpuMetrics {
        let output = Command::new("nvidia-smi")
            .args([
                "--query-gpu=utilization.gpu,memory.used,memory.total",
                "--format=csv,noheader,nounits",
            ])
            .output();
        let Ok(output) = output else { return GpuMetrics::default(); };
        if !output.status.success() {
            return GpuMetrics::default();
        }
        let text = String::from_utf8_lossy(&output.stdout);
        let values: Vec<_> = text.lines().next().unwrap_or_default().split(',').map(str::trim).collect();
        if values.len() != 3 {
            return GpuMetrics::default();
        }
        GpuMetrics {
            utilization_percent: values[0].parse().unwrap_or(0.0),
            memory_used_mib: values[1].parse().unwrap_or(0),
            memory_total_mib: values[2].parse().unwrap_or(0),
            reserved_by: None,
            available: true,
        }
    }

    fn tailscale_online(&self) -> bool {
        Command::new("tailscale")
            .args(["status", "--json"])
            .output()
            .map(|output| output.status.success())
            .unwrap_or(false)
    }
}

fn bytes_to_mib(bytes: u64) -> u32 {
    (bytes / 1024 / 1024).try_into().unwrap_or(u32::MAX)
}

#[derive(Debug, Error)]
pub enum RuntimeError {
    #[error("I/O error: {0}")]
    Io(std::io::Error),
    #[error("runtime state error: {0}")]
    State(String),
    #[error("slot not found: {0}")]
    NotFound(String),
    #[error("unsupported runtime operation: {0}")]
    Unsupported(String),
    #[error("{program} failed: {message}")]
    Command { program: String, message: String },
}

#[cfg(test)]
mod tests {
    use super::*;

    fn slot(id: &str) -> SlotSummary {
        SlotSummary {
            id: id.to_owned(),
            kind: SlotKind::Workspace,
            status: SlotStatus::Running,
            owner: None,
            allocation: ResourceAllocation { cpu_threads: 8, memory_mib: 8_192, gpu: GpuAccess::None },
            cpu_percent: 0.0,
            memory_used_mib: 0,
            endpoint: None,
            last_error: None,
        }
    }

    #[test]
    fn mock_runtime_tracks_slot_lifecycle() {
        let runtime = MockRuntime::new();
        runtime.start_slot(&slot("W1")).unwrap();
        runtime.resize_slot("W1", &ResourceAllocation { cpu_threads: 4, memory_mib: 4_096, gpu: GpuAccess::None }).unwrap();
        runtime.set_gpu_access(&slot("W1"), GpuAccess::Exclusive).unwrap();
        assert_eq!(runtime.collect_gpu_metrics().reserved_by.as_deref(), Some("W1"));
        runtime.stop_slot("W1").unwrap();
        assert!(runtime.resize_slot("W1", &ResourceAllocation::stopped()).is_err());
    }
}
