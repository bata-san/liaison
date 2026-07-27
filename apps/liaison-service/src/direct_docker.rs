use std::process::{Command, Output};

use liaison_core::{
    GpuAccess, GpuMetrics, HostMetrics, ResourceAllocation, RuntimeKind, SlotKind, SlotStatus,
    SlotSummary,
};
use liaison_runtime::{RuntimeAdapter, RuntimeCommandOutput, RuntimeError};
use sysinfo::System;

const COMMAND_OUTPUT_LIMIT: usize = 48 * 1024;

/// Docker runtime used on macOS and other non-Windows hosts.
///
/// `RuntimeKind::WslDocker` is retained as the serialized configuration value for
/// compatibility with existing clients. On non-Windows hosts the service maps that
/// value to this direct Docker adapter instead of invoking `wsl.exe`.
#[derive(Debug, Clone)]
pub struct DirectDockerRuntime {
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

impl DirectDockerRuntime {
    pub fn new(
        workspace_image: impl Into<String>,
        persistent_image: impl Into<String>,
    ) -> Self {
        Self {
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

    fn docker_raw(&self, arguments: &[String]) -> Result<Output, RuntimeError> {
        Command::new("docker")
            .args(arguments)
            .output()
            .map_err(RuntimeError::Io)
    }

    fn docker(&self, arguments: &[String]) -> Result<Output, RuntimeError> {
        let output = self.docker_raw(arguments)?;
        if output.status.success() {
            Ok(output)
        } else {
            Err(RuntimeError::Command {
                program: "docker".to_owned(),
                message: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
            })
        }
    }

    fn exists(&self, slot_id: &str) -> bool {
        self.docker(&[
            "container".to_owned(),
            "inspect".to_owned(),
            Self::container_name(slot_id),
        ])
        .is_ok()
    }

    fn reject_gpu(access: GpuAccess) -> Result<(), RuntimeError> {
        if access == GpuAccess::None {
            Ok(())
        } else {
            Err(RuntimeError::Unsupported(
                "container GPU assignment is not available on the native macOS Docker runtime"
                    .to_owned(),
            ))
        }
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
        Self::reject_gpu(allocation.gpu)?;
        let name = Self::container_name(slot_id);
        let volume = format!("liaison_{}_data", slot_id.to_ascii_lowercase());
        let memory = format!("{}m", allocation.memory_mib);
        self.docker(&[
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
            self.image_for(kind).to_owned(),
            "sh".to_owned(),
            "-lc".to_owned(),
            "trap : TERM INT; sleep infinity & wait".to_owned(),
        ])?;
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
        Self::reject_gpu(allocation.gpu)?;
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

impl RuntimeAdapter for DirectDockerRuntime {
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
        Self::reject_gpu(access)?;
        let mut allocation = slot.allocation;
        allocation.gpu = access;
        self.ensure_running(&slot.id, &allocation)
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
        GpuMetrics::default()
    }

    fn tailscale_online(&self) -> bool {
        Command::new("tailscale")
            .args(["status", "--json"])
            .output()
            .map(|output| output.status.success())
            .unwrap_or_else(|_| {
                Command::new("/Applications/Tailscale.app/Contents/MacOS/Tailscale")
                    .args(["status", "--json"])
                    .output()
                    .map(|output| output.status.success())
                    .unwrap_or(false)
            })
    }

    fn reconcile_slot(&self, slot: &SlotSummary) -> Result<(), RuntimeError> {
        if slot.status == SlotStatus::Stopped {
            self.stop_slot(&slot.id)
        } else {
            self.ensure_running(&slot.id, &slot.allocation)
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_runtime_rejects_gpu_assignment() {
        assert!(DirectDockerRuntime::reject_gpu(GpuAccess::Shared).is_err());
        assert!(DirectDockerRuntime::reject_gpu(GpuAccess::Exclusive).is_err());
        assert!(DirectDockerRuntime::reject_gpu(GpuAccess::None).is_ok());
    }

    #[test]
    fn container_names_are_stable() {
        assert_eq!(DirectDockerRuntime::container_name("W3"), "liaison-w3");
    }

    #[test]
    fn memory_and_swap_limits_are_kept_equal() {
        let allocation = ResourceAllocation {
            cpu_threads: 4,
            memory_mib: 4_096,
            gpu: GpuAccess::None,
        };
        let (_, memory) = DirectDockerRuntime::expected_limits(&allocation);
        assert!(DirectDockerRuntime::limits_match(
            ContainerLimits {
                running: true,
                nano_cpus: 4_000_000_000,
                memory_bytes: memory,
                memory_swap_bytes: memory,
            },
            &allocation,
        ));
    }
}
