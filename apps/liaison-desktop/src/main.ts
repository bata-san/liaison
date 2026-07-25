import { invoke } from "@tauri-apps/api/core";
import "./styles.css";

type Mode = "remote" | "class" | "local_exclusive" | "maintenance";
type SlotKind = "persistent" | "workspace";
type SlotStatus = "stopped" | "starting" | "running" | "throttled" | "draining" | "error";
type GpuAccess = "none" | "shared" | "exclusive";

interface Allocation {
  cpu_threads: number;
  memory_mib: number;
  gpu: GpuAccess;
}

interface SlotSummary {
  id: string;
  kind: SlotKind;
  status: SlotStatus;
  owner: string | null;
  allocation: Allocation;
  cpu_percent: number;
  memory_used_mib: number;
  endpoint: string | null;
  last_error: string | null;
}

interface PoolSummary {
  id: string;
  cpu_capacity_threads: number;
  memory_capacity_mib: number;
  cpu_allocated_threads: number;
  memory_allocated_mib: number;
}

interface SystemSnapshot {
  service_version: string;
  mode: Mode;
  runtime: "mock" | "wsl-docker";
  service_online: boolean;
  tailscale_online: boolean;
  host: { cpu_percent: number; memory_used_mib: number; memory_total_mib: number };
  gpu: {
    utilization_percent: number;
    memory_used_mib: number;
    memory_total_mib: number;
    reserved_by: string | null;
    available: boolean;
  };
  pools: PoolSummary[];
  slots: SlotSummary[];
  updated_at_unix_ms: number;
}

const app = document.querySelector<HTMLDivElement>("#app");
if (!app) throw new Error("Application root was not found");

let snapshot: SystemSnapshot | null = null;
let busy = false;
let refreshTimer: number | undefined;

const formatGiB = (mib: number): string => `${(mib / 1024).toFixed(mib < 10240 ? 1 : 0)} GB`;
const clamp = (value: number): number => Math.max(0, Math.min(100, value));
const ratio = (used: number, total: number): number => total > 0 ? clamp((used / total) * 100) : 0;
const modeLabel = (mode: Mode): string => ({
  remote: "Remote",
  class: "Class",
  local_exclusive: "Local exclusive",
  maintenance: "Maintenance"
})[mode];
const statusLabel = (status: SlotStatus): string => status.replace("_", " ");

async function call<T>(command: string, args: Record<string, unknown> = {}): Promise<T> {
  busy = true;
  document.body.classList.add("busy");
  try {
    return await invoke<T>(command, args);
  } finally {
    busy = false;
    document.body.classList.remove("busy");
  }
}

function toast(message: string, tone: "error" | "ok" = "ok"): void {
  const element = document.createElement("div");
  element.className = `toast ${tone}`;
  element.textContent = message;
  document.body.append(element);
  window.setTimeout(() => element.classList.add("visible"), 10);
  window.setTimeout(() => {
    element.classList.remove("visible");
    window.setTimeout(() => element.remove(), 240);
  }, 3200);
}

async function update(action: () => Promise<SystemSnapshot>, success?: string): Promise<void> {
  if (busy) return;
  try {
    snapshot = await action();
    render();
    if (success) toast(success);
  } catch (error) {
    toast(String(error), "error");
  }
}

async function refresh(showFailure = false): Promise<void> {
  if (busy) return;
  try {
    snapshot = await call<SystemSnapshot>("get_snapshot");
    render();
  } catch (error) {
    snapshot = null;
    renderConnectionError(String(error));
    if (showFailure) toast(String(error), "error");
  }
}

function metricCard(icon: string, label: string, value: string, detail: string, progress: number): string {
  return `<article class="metric-card">
    <header><span class="metric-icon">${icon}</span><span>${label}</span></header>
    <strong>${value}</strong>
    <div class="bar"><i style="width:${clamp(progress)}%"></i></div>
    <small>${detail}</small>
  </article>`;
}

function poolCard(pool: PoolSummary): string {
  const cpu = ratio(pool.cpu_allocated_threads, pool.cpu_capacity_threads);
  const memory = ratio(pool.memory_allocated_mib, pool.memory_capacity_mib);
  return `<article class="pool-card">
    <header><div><span class="eyebrow">RESOURCE POOL</span><h3>${pool.id}</h3></div><span class="pool-state">dynamic</span></header>
    <div class="pool-row"><span>CPU threads</span><strong>${pool.cpu_allocated_threads} / ${pool.cpu_capacity_threads}</strong></div>
    <div class="bar compact"><i style="width:${cpu}%"></i></div>
    <div class="pool-row"><span>Memory</span><strong>${formatGiB(pool.memory_allocated_mib)} / ${formatGiB(pool.memory_capacity_mib)}</strong></div>
    <div class="bar compact"><i style="width:${memory}%"></i></div>
  </article>`;
}

function slotCard(slot: SlotSummary, gpuOwner: string | null): string {
  const running = slot.status !== "stopped";
  const memory = ratio(slot.memory_used_mib, slot.allocation.memory_mib);
  const canUseGpu = slot.kind === "workspace" && running;
  const ownsGpu = gpuOwner === slot.id;
  return `<article class="slot-card ${slot.status}">
    <header>
      <div class="slot-name"><span>${slot.id}</span><small>${slot.kind}</small></div>
      <span class="status"><i></i>${statusLabel(slot.status)}</span>
    </header>
    <div class="slot-allocation">
      <div><small>CPU</small><strong>${slot.allocation.cpu_threads || "—"}</strong><span>threads</span></div>
      <div><small>RAM</small><strong>${slot.allocation.memory_mib ? formatGiB(slot.allocation.memory_mib) : "—"}</strong><span>${slot.memory_used_mib ? `${formatGiB(slot.memory_used_mib)} used` : "idle"}</span></div>
    </div>
    <div class="bar compact"><i style="width:${memory}%"></i></div>
    <footer>
      <button class="subtle" data-slot-action="${running ? "stop" : "start"}" data-slot="${slot.id}">${running ? "Stop" : "Start"}</button>
      ${canUseGpu ? `<button class="gpu-button ${ownsGpu ? "active" : ""}" data-gpu-slot="${slot.id}">${ownsGpu ? "Release GPU" : "Reserve GPU"}</button>` : ""}
    </footer>
    ${slot.last_error ? `<p class="slot-error">${escapeHtml(slot.last_error)}</p>` : ""}
  </article>`;
}

function render(): void {
  if (!snapshot) return;
  const persistent = snapshot.slots.filter((slot) => slot.kind === "persistent");
  const workspaces = snapshot.slots.filter((slot) => slot.kind === "workspace");
  const activeWorkspaces = workspaces.filter((slot) => slot.status !== "stopped").length;
  const updated = new Date(snapshot.updated_at_unix_ms).toLocaleTimeString("ja-JP", { hour: "2-digit", minute: "2-digit", second: "2-digit" });

  app.innerHTML = `<div class="app-shell">
    <aside>
      <div class="brand"><span class="logo">L</span><div><strong>Liaison</strong><small>workstation fabric</small></div></div>
      <nav>
        <button class="active"><span>◫</span>Overview</button>
        <button><span>▦</span>Slots</button>
        <button><span>◉</span>Resources</button>
        <button><span>⌁</span>Network</button>
        <button><span>⚙</span>Settings</button>
      </nav>
      <div class="runtime-card">
        <span class="eyebrow">RUNTIME</span>
        <strong>${snapshot.runtime}</strong>
        <small>service v${snapshot.service_version}</small>
      </div>
      <div class="connection ${snapshot.tailscale_online ? "online" : "offline"}"><i></i><div><strong>Tailscale</strong><small>${snapshot.tailscale_online ? "connected" : "offline"}</small></div></div>
    </aside>

    <main>
      <header class="topbar">
        <div><span class="eyebrow">THINKSTATION P620 · THREADRIPPER PRO 5965WX</span><h1>Workstation control</h1></div>
        <div class="sync"><i></i><span>Updated ${updated}</span><button id="refresh">↻</button></div>
      </header>

      <section class="mode-hero">
        <div class="mode-copy"><span class="eyebrow">ACTIVE POLICY</span><h2>${modeLabel(snapshot.mode)}</h2><p>${modeDescription(snapshot.mode)}</p></div>
        <div class="mode-switch">
          ${(["remote", "class", "local_exclusive"] as Mode[]).map((mode) => `<button data-mode="${mode}" class="${snapshot?.mode === mode ? "selected" : ""}"><span>${modeIcon(mode)}</span><strong>${modeLabel(mode)}</strong></button>`).join("")}
        </div>
      </section>

      <section class="metrics-grid">
        ${metricCard("⌁", "Host CPU", `${snapshot.host.cpu_percent.toFixed(0)}%`, "48 hardware threads", snapshot.host.cpu_percent)}
        ${metricCard("▤", "System memory", formatGiB(snapshot.host.memory_used_mib), `${formatGiB(snapshot.host.memory_total_mib)} installed`, ratio(snapshot.host.memory_used_mib, snapshot.host.memory_total_mib))}
        ${metricCard("◈", "GPU load", snapshot.gpu.available ? `${snapshot.gpu.utilization_percent.toFixed(0)}%` : "N/A", snapshot.gpu.reserved_by ? `reserved by ${snapshot.gpu.reserved_by}` : "available", snapshot.gpu.utilization_percent)}
        ${metricCard("▰", "GPU memory", snapshot.gpu.available ? formatGiB(snapshot.gpu.memory_used_mib) : "N/A", snapshot.gpu.available ? `${formatGiB(snapshot.gpu.memory_total_mib)} total` : "nvidia-smi unavailable", ratio(snapshot.gpu.memory_used_mib, snapshot.gpu.memory_total_mib))}
      </section>

      <section class="workspace-control">
        <div><span class="eyebrow">DYNAMIC SPLIT</span><h2>Workspace slots</h2><p>Split the same pool among active users. Fewer slots receive more CPU and memory.</p></div>
        <div class="slot-count">
          ${[0,1,2,3,4,5].map((count) => `<button data-count="${count}" class="${activeWorkspaces === count ? "selected" : ""}">${count}</button>`).join("")}
        </div>
      </section>

      <section class="content-grid">
        <div class="left-column">
          <div class="section-heading"><div><span class="eyebrow">ALWAYS ON</span><h2>Persistent layer</h2></div><span>${persistent.filter((slot) => slot.status !== "stopped").length}/2 active</span></div>
          <div class="slot-grid persistent">${persistent.map((slot) => slotCard(slot, snapshot?.gpu.reserved_by ?? null)).join("")}</div>
          <div class="section-heading workspace-heading"><div><span class="eyebrow">ON DEMAND</span><h2>Workspace layer</h2></div><span>${activeWorkspaces}/5 active</span></div>
          <div class="slot-grid">${workspaces.map((slot) => slotCard(slot, snapshot?.gpu.reserved_by ?? null)).join("")}</div>
        </div>
        <div class="right-column">
          <div class="section-heading"><div><span class="eyebrow">CAPACITY</span><h2>Resource pools</h2></div></div>
          <div class="pool-stack">${snapshot.pools.map(poolCard).join("")}</div>
          <article class="policy-card">
            <span class="eyebrow">SAFETY</span><h3>Teacher priority remains local</h3>
            <p>Local-exclusive mode stops workspace slots but leaves persistent services untouched.</p>
            <ul><li>Loopback-only control API</li><li>Token-authenticated commands</li><li>No Docker socket inside slots</li></ul>
          </article>
        </div>
      </section>
    </main>
  </div>`;
  bindEvents();
}

function bindEvents(): void {
  document.querySelector<HTMLButtonElement>("#refresh")?.addEventListener("click", () => void refresh(true));
  document.querySelectorAll<HTMLButtonElement>("[data-mode]").forEach((button) => {
    button.addEventListener("click", () => void update(
      () => call<SystemSnapshot>("set_mode", { mode: button.dataset.mode }),
      `Mode changed to ${button.textContent?.trim() ?? "selected mode"}`
    ));
  });
  document.querySelectorAll<HTMLButtonElement>("[data-count]").forEach((button) => {
    button.addEventListener("click", () => void update(
      () => call<SystemSnapshot>("rebalance", { activeWorkspaceSlots: Number(button.dataset.count) }),
      `Workspace pool split into ${button.dataset.count} slot(s)`
    ));
  });
  document.querySelectorAll<HTMLButtonElement>("[data-slot-action]").forEach((button) => {
    const command = button.dataset.slotAction === "start" ? "start_slot" : "stop_slot";
    button.addEventListener("click", () => void update(
      () => call<SystemSnapshot>(command, { slotId: button.dataset.slot }),
      `${button.dataset.slot} ${button.dataset.slotAction === "start" ? "started" : "stopped"}`
    ));
  });
  document.querySelectorAll<HTMLButtonElement>("[data-gpu-slot]").forEach((button) => {
    const slotId = button.dataset.gpuSlot ?? "";
    const ownsGpu = snapshot?.gpu.reserved_by === slotId;
    button.addEventListener("click", () => void update(
      () => ownsGpu
        ? call<SystemSnapshot>("release_gpu")
        : call<SystemSnapshot>("reserve_gpu", { slotId, access: "exclusive" }),
      ownsGpu ? "GPU released" : `GPU reserved by ${slotId}`
    ));
  });
}

function renderConnectionError(message: string): void {
  app.innerHTML = `<div class="connection-screen"><div class="connection-dialog"><span class="logo large">L</span><span class="eyebrow">SERVICE OFFLINE</span><h1>Connect to Liaison Service</h1><p>The local control service did not answer. Start the mock service for a safe demo, or install the Windows service.</p><code>${escapeHtml(message)}</code><button id="retry">Retry connection</button><small>Demo: powershell -ExecutionPolicy Bypass -File scripts/run-demo.ps1</small></div></div>`;
  document.querySelector<HTMLButtonElement>("#retry")?.addEventListener("click", () => void refresh(true));
}

function modeDescription(mode: Mode): string {
  return {
    remote: "Workspace users receive the full remote resource pool and may reserve the GPU.",
    class: "Workspace slots stay alive with reduced limits while the teacher uses Windows locally.",
    local_exclusive: "Workspace slots stop. Persistent services remain available with minimal overhead.",
    maintenance: "All managed slots stop while an administrator performs maintenance."
  }[mode];
}

function modeIcon(mode: Mode): string {
  return ({ remote: "⌁", class: "▣", local_exclusive: "◉", maintenance: "⚙" })[mode];
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>'"]/g, (character) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"
  })[character] ?? character);
}

void refresh();
refreshTimer = window.setInterval(() => void refresh(), 2500);
window.addEventListener("beforeunload", () => window.clearInterval(refreshTimer));
