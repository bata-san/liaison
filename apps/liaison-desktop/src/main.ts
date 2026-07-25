import { invoke } from "@tauri-apps/api/core";
import "./styles.css";

type Mode = "remote" | "class" | "local_exclusive" | "maintenance";
type SlotStatus = "stopped" | "starting" | "running" | "throttled" | "draining" | "error";
type GpuAccess = "none" | "shared" | "exclusive";

interface SlotSummary {
  id: string;
  kind: "persistent" | "workspace";
  status: SlotStatus;
  owner: string | null;
  allocation: { cpu_threads: number; memory_mib: number; gpu: GpuAccess };
  cpu_percent: number;
  memory_used_mib: number;
}

interface SystemSnapshot {
  mode: Mode;
  tailscale_online: boolean;
  host: { cpu_percent: number; memory_used_mib: number; memory_total_mib: number };
  gpu: {
    utilization_percent: number;
    memory_used_mib: number;
    memory_total_mib: number;
    reserved_by: string | null;
  };
  pools: Array<{
    id: string;
    cpu_capacity_threads: number;
    memory_capacity_mib: number;
    cpu_allocated_threads: number;
    memory_allocated_mib: number;
  }>;
  slots: SlotSummary[];
}

const app = document.querySelector<HTMLDivElement>("#app");
if (!app) throw new Error("Application root was not found");

const formatGiB = (mib: number) => `${(mib / 1024).toFixed(1)} GB`;
const percent = (value: number, total: number) => total === 0 ? 0 : Math.min(100, (value / total) * 100);

function modeLabel(mode: Mode): string {
  return {
    remote: "Remote",
    class: "Class",
    local_exclusive: "Local exclusive",
    maintenance: "Maintenance",
  }[mode];
}

function statusLabel(status: SlotStatus): string {
  return status.charAt(0).toUpperCase() + status.slice(1);
}

function metricCard(label: string, value: string, detail: string, progressValue: number): string {
  return `
    <article class="metric-card">
      <div class="metric-head"><span>${label}</span><strong>${value}</strong></div>
      <div class="progress"><i style="width:${Math.min(100, progressValue)}%"></i></div>
      <small>${detail}</small>
    </article>`;
}

function slotCard(slot: SlotSummary): string {
  const memoryRatio = percent(slot.memory_used_mib, slot.allocation.memory_mib);
  const gpuBadge = slot.allocation.gpu === "none" ? "" : `<span class="gpu-badge">GPU ${slot.allocation.gpu}</span>`;
  return `
    <article class="slot-card ${slot.status}">
      <header>
        <div>
          <span class="slot-id">${slot.id}</span>
          <span class="kind">${slot.kind}</span>
        </div>
        <span class="status-dot"><i></i>${statusLabel(slot.status)}</span>
      </header>
      <div class="slot-stats">
        <div><span>CPU limit</span><strong>${slot.allocation.cpu_threads || "—"}</strong></div>
        <div><span>Memory</span><strong>${slot.allocation.memory_mib ? formatGiB(slot.allocation.memory_mib) : "—"}</strong></div>
      </div>
      <div class="mini-progress"><i style="width:${memoryRatio}%"></i></div>
      <footer>
        <span>${slot.memory_used_mib ? `${formatGiB(slot.memory_used_mib)} in use` : "Inactive"}</span>
        ${gpuBadge}
      </footer>
    </article>`;
}

function render(snapshot: SystemSnapshot): void {
  const persistent = snapshot.slots.filter((slot) => slot.kind === "persistent");
  const workspace = snapshot.slots.filter((slot) => slot.kind === "workspace");
  const ramPercent = percent(snapshot.host.memory_used_mib, snapshot.host.memory_total_mib);
  const gpuMemoryPercent = percent(snapshot.gpu.memory_used_mib, snapshot.gpu.memory_total_mib);

  app.innerHTML = `
    <div class="shell">
      <aside class="sidebar">
        <div class="brand"><span class="brand-mark">L</span><div><strong>Liaison</strong><small>Workstation orchestrator</small></div></div>
        <nav>
          <button class="active">Overview</button>
          <button>Slots</button>
          <button>Resource pools</button>
          <button>Audit</button>
          <button>Settings</button>
        </nav>
        <div class="connection ${snapshot.tailscale_online ? "online" : "offline"}">
          <i></i><div><strong>Tailscale</strong><small>${snapshot.tailscale_online ? "Connected" : "Offline"}</small></div>
        </div>
      </aside>

      <main>
        <header class="topbar">
          <div><span class="eyebrow">THINKSTATION P620</span><h1>System overview</h1></div>
          <div class="mode-pill"><i></i>${modeLabel(snapshot.mode)}</div>
        </header>

        <section class="mode-panel">
          <div><span class="eyebrow">OPERATING MODE</span><h2>Choose who gets priority</h2><p>Persistent services remain protected while the workspace pool is resized.</p></div>
          <div class="mode-actions">
            ${(["remote", "class", "local_exclusive"] as Mode[]).map((mode) => `
              <button data-mode="${mode}" class="${snapshot.mode === mode ? "selected" : ""}">${modeLabel(mode)}</button>
            `).join("")}
          </div>
        </section>

        <section class="metrics">
          ${metricCard("Host CPU", `${snapshot.host.cpu_percent.toFixed(0)}%`, "48 hardware threads", snapshot.host.cpu_percent)}
          ${metricCard("System memory", formatGiB(snapshot.host.memory_used_mib), `${formatGiB(snapshot.host.memory_total_mib)} installed`, ramPercent)}
          ${metricCard("GPU load", `${snapshot.gpu.utilization_percent.toFixed(0)}%`, snapshot.gpu.reserved_by ? `Reserved by ${snapshot.gpu.reserved_by}` : "Not reserved", snapshot.gpu.utilization_percent)}
          ${metricCard("GPU memory", formatGiB(snapshot.gpu.memory_used_mib), `${formatGiB(snapshot.gpu.memory_total_mib)} available`, gpuMemoryPercent)}
        </section>

        <section class="section-block">
          <div class="section-title"><div><span class="eyebrow">ALWAYS ON</span><h2>Persistent pool</h2></div><span>${persistent.filter((slot) => slot.status !== "stopped").length}/${persistent.length} active</span></div>
          <div class="slot-grid persistent-grid">${persistent.map(slotCard).join("")}</div>
        </section>

        <section class="section-block">
          <div class="section-title"><div><span class="eyebrow">DYNAMIC CAPACITY</span><h2>Workspace pool</h2></div><span>${workspace.filter((slot) => slot.status !== "stopped").length}/${workspace.length} allocated</span></div>
          <div class="slot-grid">${workspace.map(slotCard).join("")}</div>
        </section>
      </main>
    </div>`;

  document.querySelectorAll<HTMLButtonElement>("[data-mode]").forEach((button) => {
    button.addEventListener("click", async () => {
      const mode = button.dataset.mode as Mode;
      button.disabled = true;
      try {
        const next = await invoke<SystemSnapshot>("set_mode", { mode });
        render(next);
      } finally {
        button.disabled = false;
      }
    });
  });
}

async function bootstrap(): Promise<void> {
  try {
    render(await invoke<SystemSnapshot>("get_snapshot"));
  } catch (error) {
    app.innerHTML = `<div class="fatal"><strong>Liaison could not start</strong><pre>${String(error)}</pre></div>`;
  }
}

void bootstrap();
