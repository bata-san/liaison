use std::{
    collections::HashMap,
    process::{Command, Output},
    sync::Mutex,
};

use liaison_core::{
    GpuAccess, GpuMetrics, HostMetrics, ResourceAllocation, RuntimeKind, SlotKind, SlotStatus,
    SlotSummary,
};
use sysinfo::System;
use thiserror::Error;

const COMMAND_OUTPUT_LIMIT: usize = 48 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeCommandOutput {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
    pub truncated: bool,
}

pub trait RuntimeAdapter: Send + Sync {
    fn kind(&self) -> RuntimeKind;
    fn start_slot(&self, slot: &SlotSummary) -> Result<(), RuntimeError>;
    fn stop_slot(&self, slot_id: &str) -> Result<(), RuntimeError>;
    fn resize_slot(
        &self,
        slot_id: &str,
        allocation: &ResourceAllocation,
    ) -> Result<(), RuntimeError>;
    fn set_gpu_access(
        &self,
        slot: &SlotSummary,
        access: GpuAccess,
    ) -> Result<(), RuntimeError>;
    fn collect_host_metrics(&self) -> HostMetrics;
    fn collect_gpu_metrics(&self) -> GpuMetrics;
    fn tailscale_online(&self) -> bool;

    fn reconcile_slot(&self, slot: &SlotSummary) -> Result<(), RuntimeError> {
        if slot.status == SlotStatus::Stopped {
            self.stop_slot(&slot.id)
        } else {
            self.start_slot(slot)
        }
    }

    fn exec_workspace(
        &self,
        slot_id: &str,
        command: &str,
        working_directory: &str,
    ) -> Result<RuntimeCommandOutput, RuntimeError>;

    fn stop_all(&self) -> Result<(), RuntimeError>;
}

#[derive(Debug, Default)]
pub struct MockRuntime {
    slots: Mutex<HashMap<String, ResourceAllocation>>,
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
            .insert(slot.id.clone(), slot.allocation);
        Ok(())
    }

    fn stop_slot(&self, slot_id: &str) -> Result<(), RuntimeError> {
        self.slots
            .lock()
            .map_err(|_| RuntimeError::State("mock runtime lock poisoned".to_owned()))?
            .remove(slot_id);
        Ok(())
    }

    fn resize_slot(
        &self,
        slot_id: &str,
        allocation: &ResourceAllocation,
    ) -> Result<(), RuntimeError> {
        let mut slots = self
            .slots
            .lock()
            .map_err(|_| RuntimeError::State("mock runtime lock poisoned".to_owned()))?;
        if !slots.contains_key(slot_id) {
            return Err(RuntimeError::NotFound(slot_id.to_owned()));
        }
        slots.insert(slot_id.to_owned(), *allocation);
        Ok(())
    }

    fn set_gpu_access(
        &self,
        slot: &SlotSummary,
        access: GpuAccess,
    ) -> Result<(), RuntimeError> {
        let mut slots = self
            .slots
            .lock()
            .map_err(|_| RuntimeError::State("mock runtime lock poisoned".to_owned()))?;
        let allocation = slots
            .get_mut(&slot.id)
            .ok_or_else(|| RuntimeError::NotFound(slot.id.clone()))?;
        *allocation = slot.allocation;
        allocation.gpu = access;
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
        let slots = self.slots.lock().ok();
        let exclusive_owner = slots.as_ref().and_then(|slots| {
            slots.iter().find_map(|(slot_id, allocation)| {
                (allocation.gpu == GpuAccess::Exclusive).then(|| slot_id.clone())
            })
        });
        let gpu_active = slots.as_ref().is_some_and(|slots| {
            slots
                .values()
                .any(|allocation| allocation.gpu != GpuAccess::None)
        });
        GpuMetrics {
            utilization_percent: if gpu_active { 47.0 } else { 2.0 },
            memory_used_mib: if gpu_active { 12_288 } else { 768 },
            memory_total_mib: 49_152,
            reserved_by: exclusive_owner,
            available: true,
        }
    }

    fn tailscale_online(&self) -> bool {
        true
    }

    fn exec_workspace(
        &self,
        slot_id: &str,
        command: &str,
        working_directory: &str,
    ) -> Result<RuntimeCommandOutput, RuntimeError> {
        let slots = self
            .slots
            .lock()
            .map_err(|_| RuntimeError::State("mock runtime lock poisoned".to_owned()))?;
        if !slots.contains_key(slot_id) {
            return Err(RuntimeError::NotFound(slot_id.to_owned()));
        }
        Ok(RuntimeCommandOutput {
            exit_code: 0,
            stdout: format!("mock {slot_id}:{working_directory}$ {command}\n"),
            stderr: String::new(),
            truncated: false,
        })
    }

    fn stop_all(&self) -> Result<(), RuntimeError> {
        self.slots
            .lock()
            .map_err(|_| RuntimeError::State("mock runtime lock poisoned".to_owned()))?
            .clear();
        Ok(())
    }
}

#[derive(Debug, Clone)]
pub struct WslDockerRuntime {
    distribution: String,
    workspace_image: String,
    persistent_image: String,
}

#[derive(Debug, Clone, Copy)]
struct ContainerLimits {
    running: bool,
    nano_cpus: i64,
    memory_bytes: i64,
    memory_swap_bytes: i64,
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

    fn slot_kind(slot_id: &str) -> Result<SlotKind, RuntimeError> {
        match slot_id.chars().next().map(|value| value.to_ascii_uppercase()) {
            Some('P') => Ok(SlotKind::Persistent),
            Some('W') => Ok(SlotKind::Workspace),
            _ => Err(RuntimeError::State(format!("invalid slot id: {slot_id}"))),
        }
    }

    fn image_for(&self, kind: SlotKind) -> &str {
        match kind {
            SlotKind::Persistent => &self.persistent_image,
            SlotKind::Workspace => &self.workspace_image,
        }
    }

    fn run_wsl_raw(&self, arguments: &[String]) -> Result<Output, RuntimeError> {
        Command::new("wsl.exe")
            .arg("-d")
            .arg(&self.distribution)
            .arg("--")
            .args(arguments)
            .output()
            .map_err(RuntimeError::Io)
    }

    fn run_wsl(&self, arguments: &[String]) -> Result<Output, RuntimeError> {
        let output = self.run_wsl_raw(arguments)?;
        if output.status.success() {
            Ok(output)
        } else {
            Err(RuntimeError::Command {
                program: "wsl.exe".to_owned(),
                message: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
            })
        }
    }

    fn docker_raw(&self, arguments: &[String]) -> Result<Output, RuntimeError> {
        let mut command = vec!["docker".to_owned()];
        command.extend_from_slice(arguments);
        self.run_wsl_raw(&command)
    }

    fn docker(&self, arguments: &[String]) -> Result<Output, RuntimeError> {
        let mut command = vec!["docker".to_owned()];
        command.extend_from_slice(arguments);
        self.run_wsl(&command)
    }

    fn exists(&self, slot_id: &str) -> bool {
        self.docker(&[
            "container".to_owned(),
            "inspect".to_owned(),
            Self::container_name(slot_id),
        ])
        .is_ok()
    }

    fn inspect_limits(&self, slot_id: &str) -> Result<ContainerLimits, RuntimeError> {
        let output = self.docker(&[
            "inspect".to_owned(),
            "--format".to_owned(),
            "{{.State.Running}}|{{.HostConfig.NanoCpus}}|{{.HostConfig.Memory}}|{{.HostConfig.MemorySwap}}".to_owned(),
            Self::container_name(slot_id),
        ])?;
        let text = String::from_utf8_lossy(&output.stdout);
        let values: Vec<_> = text.trim().split('|').collect();
        if values.len() != 4 {
            return Err(RuntimeError::State(format!(
                "unexpected Docker inspect result for {slot_id}: {}",
                text.trim()
            )));
        }
        Ok(ContainerLimits {
            running: values[0] == "true",
            nano_cpus: values[1].parse().unwrap_or_default(),
            memory_bytes: values[2].parse().unwrap_or_default(),
            memory_swap_bytes: values[3].parse().unwrap_or_default(),
        })
    }

    fn expected_limits(allocation: &ResourceAllocation) -> (i64, i64) {
        (
            i64::from(allocation.cpu_threads) * 1_000_000_000,
            i64::from(allocation.memory_mib) * 1024 * 1024,
        )
    }

    fn limits_match(limits: ContainerLimits, allocation: &ResourceAllocation) -> bool {
        let (nano_cpus, memory_bytes) = Self::expected_limits(allocation);
        limits.nano_cpus == nano_cpus
            && limits.memory_bytes == memory_bytes
            && limits.memory_swap_bytes == memory_bytes
    }

    fn update_limits(
        &self,
        slot_id: &str,
        allocation: &ResourceAllocation,
    ) -> Result<(), RuntimeError> {
        let memory = format!("{}m", allocation.memory_mib);
        self.docker(&[
            "update".to_owned(),
            "--cpus".to_owned(),
            allocation.cpu_threads.to_string(),
            "--memory".to_owned(),
            memory.clone(),
            "--memory-swap".to_owned(),
            memory,
            Self::container_name(slot_id),
        ])?;
        Ok(())
    }

    fn run_container(
        &self,
        slot_id: &str,
        kind: SlotKind,
        allocation: &ResourceAllocation,
    ) -> Result<(), RuntimeError> {
        let name = Self::container_name(slot_id);
        let volume = format!("liaison_{}_data", slot_id.to_ascii_lowercase());
        let memory = format!("{}m", allocation.memory_mib);
        let mut arguments = vec![
            "run".to_owned(),
            "--detach".to_owned(),
            "--name".to_owned(),
            name,
            "--restart".to_owned(),
            if kind == SlotKind::Persistent {
                "unless-stopped"
            } else {
                "no"
            }
            .to_owned(),
            "--cpus".to_owned(),
            allocation.cpu_threads.to_string(),
            "--memory".to_owned(),
            memory.clone(),
            "--memory-swap".to_owned(),
            memory,
            "--label".to_owned(),
            format!("liaison.slot={slot_id}"),
            "--volume".to_owned(),
            format!("{volume}:/workspace"),
        ];
        if allocation.gpu != GpuAccess::None {
            arguments.extend(["--gpus".to_owned(), "all".to_owned()]);
        }
        arguments.extend([
            self.image_for(kind).to_owned(),
            "sh".to_owned(),
            "-lc".to_owned(),
            "trap : TERM INT; sleep infinity & wait".to_owned(),
        ]);
        self.docker(&arguments)?;
        Ok(())
    }

    fn remove_container(&self, slot_id: &str) -> Result<(), RuntimeError> {
        let name = Self::container_name(slot_id);
        let _ = self.docker(&[
            "stop".to_owned(),
            "--time".to_owned(),
            "20".to_owned(),
            name.clone(),
        ]);
        self.docker(&["rm".to_owned(), "--force".to_owned(), name])?;
        Ok(())
    }

    fn recreate(
        &self,
        slot_id: &str,
        allocation: &ResourceAllocation,
    ) -> Result<(), RuntimeError> {
        let kind = Self::slot_kind(slot_id)?;
        if self.exists(slot_id) {
            self.remove_container(slot_id)?;
        }
        self.run_container(slot_id, kind, allocation)
    }

    fn ensure_running(
        &self,
        slot_id: &str,
        allocation: &ResourceAllocation,
    ) -> Result<(), RuntimeError> {
        if !self.exists(slot_id) {
            return self.recreate(slot_id, allocation);
        }

        if self.update_limits(slot_id, allocation).is_err() {
            return self.recreate(slot_id, allocation);
        }
        let limits = self.inspect_limits(slot_id)?;
        if !Self::limits_match(limits, allocation) {
            return self.recreate(slot_id, allocation);
        }
        if !limits.running {
            self.docker(&["start".to_owned(), Self::container_name(slot_id)])?;
        }
        let verified = self.inspect_limits(slot_id)?;
        if !verified.running || !Self::limits_match(verified, allocation) {
            return self.recreate(slot_id, allocation);
        }
        Ok(())
    }
}

impl RuntimeAdapter for WslDockerRuntime {
    fn kind(&self) -> RuntimeKind {
        RuntimeKind::WslDocker
    }

    fn start_slot(&self, slot: &SlotSummary) -> Result<(), RuntimeError> {
        self.ensure_running(&slot.id, &slot.allocation)
    }

    fn stop_slot(&self, slot_id: &str) -> Result<(), RuntimeError> {
        if !self.exists(slot_id) {
            return Ok(());
        }
        self.docker(&[
            "stop".to_owned(),
            "--time".to_owned(),
            "20".to_owned(),
            Self::container_name(slot_id),
        ])?;
        Ok(())
    }

    fn resize_slot(
        &self,
        slot_id: &str,
        allocation: &ResourceAllocation,
    ) -> Result<(), RuntimeError> {
        self.ensure_running(slot_id, allocation)
    }

    fn set_gpu_access(
        &self,
        slot: &SlotSummary,
        access: GpuAccess,
    ) -> Result<(), RuntimeError> {
        let mut updated = slot.allocation;
        updated.gpu = access;
        self.recreate(&slot.id, &updated)
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
        let Ok(output) = output else {
            return GpuMetrics::default();
        };
        if !output.status.success() {
            return GpuMetrics::default();
        }
        let text = String::from_utf8_lossy(&output.stdout);
        let values: Vec<_> = text
            .lines()
            .next()
            .unwrap_or_default()
            .split(',')
            .map(str::trim)
            .collect();
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

    fn exec_workspace(
        &self,
        slot_id: &str,
        command: &str,
        working_directory: &str,
    ) -> Result<RuntimeCommandOutput, RuntimeError> {
        if Self::slot_kind(slot_id)? != SlotKind::Workspace {
            return Err(RuntimeError::Unsupported(
                "commands can only run in workspace slots".to_owned(),
            ));
        }
        if !self.exists(slot_id) {
            return Err(RuntimeError::NotFound(slot_id.to_owned()));
        }
        let output = self.docker_raw(&[
            "exec".to_owned(),
            "--workdir".to_owned(),
            working_directory.to_owned(),
            Self::container_name(slot_id),
            "sh".to_owned(),
            "-lc".to_owned(),
            command.to_owned(),
        ])?;
        Ok(runtime_output(output))
    }

    fn stop_all(&self) -> Result<(), RuntimeError> {
        let output = self.docker(&[
            "ps".to_owned(),
            "--all".to_owned(),
            "--quiet".to_owned(),
            "--filter".to_owned(),
            "label=liaison.slot".to_owned(),
        ])?;
        for id in String::from_utf8_lossy(&output.stdout)
            .lines()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            self.docker(&[
                "stop".to_owned(),
                "--time".to_owned(),
                "20".to_owned(),
                id.to_owned(),
            ])?;
        }
        Ok(())
    }
}

fn runtime_output(output: Output) -> RuntimeCommandOutput {
    let (stdout, stdout_truncated) = truncate_output(String::from_utf8_lossy(&output.stdout).into_owned());
    let (stderr, stderr_truncated) = truncate_output(String::from_utf8_lossy(&output.stderr).into_owned());
    RuntimeCommandOutput {
        exit_code: output.status.code().unwrap_or(-1),
        stdout,
        stderr,
        truncated: stdout_truncated || stderr_truncated,
    }
}

fn truncate_output(mut value: String) -> (String, bool) {
    if value.len() <= COMMAND_OUTPUT_LIMIT {
        return (value, false);
    }
    let mut end = COMMAND_OUTPUT_LIMIT;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value.truncate(end);
    value.push_str("\n… output truncated …\n");
    (value, true)
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
            allocation: ResourceAllocation {
                cpu_threads: 8,
                memory_mib: 8_192,
                gpu: GpuAccess::None,
            },
            cpu_percent: 0.0,
            memory_used_mib: 0,
            endpoint: None,
            last_error: None,
        }
    }

    #[test]
    fn mock_runtime_tracks_slot_lifecycle_and_shared_gpu() {
        let runtime = MockRuntime::new();
        runtime.start_slot(&slot("W1")).unwrap();
        runtime.start_slot(&slot("W2")).unwrap();
        runtime
            .resize_slot(
                "W1",
                &ResourceAllocation {
                    cpu_threads: 4,
                    memory_mib: 4_096,
                    gpu: GpuAccess::None,
                },
            )
            .unwrap();

        let mut w1 = slot("W1");
        w1.allocation.gpu = GpuAccess::Shared;
        runtime.set_gpu_access(&w1, GpuAccess::Shared).unwrap();
        let mut w2 = slot("W2");
        w2.allocation.gpu = GpuAccess::Shared;
        runtime.set_gpu_access(&w2, GpuAccess::Shared).unwrap();
        assert!(runtime.collect_gpu_metrics().reserved_by.is_none());
        assert_eq!(runtime.collect_gpu_metrics().utilization_percent, 47.0);

        w1.allocation.gpu = GpuAccess::Exclusive;
        runtime
            .set_gpu_access(&w1, GpuAccess::Exclusive)
            .unwrap();
        assert_eq!(
            runtime.collect_gpu_metrics().reserved_by.as_deref(),
            Some("W1")
        );
        runtime.stop_slot("W1").unwrap();
        assert!(runtime
            .resize_slot("W1", &ResourceAllocation::stopped())
            .is_err());
    }

    #[test]
    fn mock_shutdown_stops_every_slot() {
        let runtime = MockRuntime::new();
        runtime.start_slot(&slot("W1")).unwrap();
        runtime.start_slot(&slot("W2")).unwrap();
        runtime.stop_all().unwrap();
        assert!(runtime.exec_workspace("W1", "pwd", "/workspace").is_err());
    }

    #[test]
    fn output_truncation_is_utf8_safe() {
        let text = "あ".repeat(COMMAND_OUTPUT_LIMIT);
        let (truncated, changed) = truncate_output(text);
        assert!(changed);
        assert!(truncated.is_char_boundary(truncated.len()));
    }
}
