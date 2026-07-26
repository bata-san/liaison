use std::process::{Command, Output};

use liaison_core::{
    GpuAccess, GpuMetrics, HostMetrics, ResourceAllocation, RuntimeKind, SlotKind, SlotSummary,
};
use liaison_runtime::{RuntimeAdapter, RuntimeError};
use sysinfo::System;

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

    fn image_for(&self, kind: SlotKind) -> &str {
        match kind {
            SlotKind::Persistent => &self.persistent_image,
            SlotKind::Workspace => &self.workspace_image,
        }
    }

    fn docker(&self, arguments: &[String]) -> Result<Output, RuntimeError> {
        let output = Command::new("docker")
            .args(arguments)
            .output()
            .map_err(RuntimeError::Io)?;
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
}

impl RuntimeAdapter for DirectDockerRuntime {
    fn kind(&self) -> RuntimeKind {
        RuntimeKind::WslDocker
    }

    fn start_slot(&self, slot: &SlotSummary) -> Result<(), RuntimeError> {
        Self::reject_gpu(slot.allocation.gpu)?;
        let name = Self::container_name(&slot.id);
        if self.exists(&slot.id) {
            self.docker(&["start".to_owned(), name])?;
            return self.resize_slot(&slot.id, &slot.allocation);
        }

        let volume = format!("liaison_{}_data", slot.id.to_ascii_lowercase());
        self.docker(&[
            "run".to_owned(),
            "--detach".to_owned(),
            "--name".to_owned(),
            name,
            "--restart".to_owned(),
            if slot.kind == SlotKind::Persistent {
                "unless-stopped"
            } else {
                "no"
            }
            .to_owned(),
            "--cpus".to_owned(),
            slot.allocation.cpu_threads.to_string(),
            "--memory".to_owned(),
            format!("{}m", slot.allocation.memory_mib),
            "--label".to_owned(),
            format!("liaison.slot={}", slot.id),
            "--volume".to_owned(),
            format!("{volume}:/workspace"),
            self.image_for(slot.kind).to_owned(),
            "sh".to_owned(),
            "-lc".to_owned(),
            "trap : TERM INT; sleep infinity & wait".to_owned(),
        ])?;
        Ok(())
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
        Self::reject_gpu(allocation.gpu)?;
        if !self.exists(slot_id) {
            return Err(RuntimeError::NotFound(slot_id.to_owned()));
        }
        self.docker(&[
            "update".to_owned(),
            "--cpus".to_owned(),
            allocation.cpu_threads.to_string(),
            "--memory".to_owned(),
            format!("{}m", allocation.memory_mib),
            Self::container_name(slot_id),
        ])?;
        Ok(())
    }

    fn set_gpu_access(
        &self,
        _slot: &SlotSummary,
        access: GpuAccess,
    ) -> Result<(), RuntimeError> {
        Self::reject_gpu(access)
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
}
