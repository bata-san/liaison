import { invoke } from "@tauri-apps/api/core";
import { useCallback, useEffect, useMemo, useState } from "react";

type Mode = "remote" | "class" | "local_exclusive" | "maintenance";
type SlotKind = "persistent" | "workspace";
type SlotStatus = "stopped" | "starting" | "running" | "throttled" | "draining" | "error";
type GpuAccess = "none" | "shared" | "exclusive";
type ResourceMetric = "cpu" | "memory";

interface Allocation {
  cpu_threads: number;
  memory_mib: number;
  gpu: GpuAccess;
}

interface Worker {
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
  host: {
    cpu_percent: number;
    memory_used_mib: number;
    memory_total_mib: number;
  };
  gpu: {
    utilization_percent: number;
    memory_used_mib: number;
    memory_total_mib: number;
    reserved_by: string | null;
    available: boolean;
  };
  pools: PoolSummary[];
  slots: Worker[];
  updated_at_unix_ms: number;
}

const MODES: Array<{ value: Mode; label: string; description: string }> = [
  { value: "remote", label: "Remote", description: "全workerへ通常容量を割り当て、GPU予約を許可します。" },
  { value: "class", label: "Class", description: "workerを維持したまま、授業用の縮小容量へ詰め直します。" },
  { value: "local_exclusive", label: "Local", description: "workspace workerを外し、Windows側の利用を優先します。" },
  { value: "maintenance", label: "Maintenance", description: "管理対象workerを停止し、保守状態へ移行します。" }
];

const WORKER_COLORS = ["cyan", "violet", "amber", "green", "rose"] as const;

function formatGiB(mib: number): string {
  const gib = mib / 1024;
  return `${gib < 10 ? gib.toFixed(1) : gib.toFixed(0)} GiB`;
}

function formatPercent(value: number): string {
  return `${Math.max(0, Math.min(100, value)).toFixed(0)}%`;
}

function workerColor(worker: Worker): string {
  if (worker.kind === "persistent") return "persistent";
  const index = Math.max(0, Number.parseInt(worker.id.replace(/\D/g, ""), 10) - 1);
  return WORKER_COLORS[index % WORKER_COLORS.length];
}

function allocationFor(worker: Worker, metric: ResourceMetric): number {
  return metric === "cpu" ? worker.allocation.cpu_threads : worker.allocation.memory_mib;
}

function capacityFor(pool: PoolSummary, metric: ResourceMetric): number {
  return metric === "cpu" ? pool.cpu_capacity_threads : pool.memory_capacity_mib;
}

function allocationLabel(value: number, metric: ResourceMetric): string {
  return metric === "cpu" ? `${value} threads` : formatGiB(value);
}

async function command<T>(name: string, args: Record<string, unknown> = {}): Promise<T> {
  return invoke<T>(name, args);
}

function StatusDot({ online }: { online: boolean }) {
  return <span className={`status-dot ${online ? "online" : "offline"}`} aria-hidden="true" />;
}

function MetricCard({ label, value, detail, progress }: { label: string; value: string; detail: string; progress: number }) {
  return (
    <article className="metric-card">
      <span className="eyebrow">{label}</span>
      <strong>{value}</strong>
      <div className="meter" aria-hidden="true">
        <span style={{ width: `${Math.max(0, Math.min(100, progress))}%` }} />
      </div>
      <small>{detail}</small>
    </article>
  );
}

function ResourceTrack({
  title,
  metric,
  pool,
  workers
}: {
  title: string;
  metric: ResourceMetric;
  pool: PoolSummary;
  workers: Worker[];
}) {
  const capacity = capacityFor(pool, metric);
  const activeWorkers = workers.filter((worker) => worker.status !== "stopped" && allocationFor(worker, metric) > 0);
  const allocated = activeWorkers.reduce((sum, worker) => sum + allocationFor(worker, metric), 0);
  const free = Math.max(0, capacity - allocated);

  return (
    <section className="resource-track">
      <header>
        <div>
          <span className="eyebrow">{title}</span>
          <strong>{metric === "cpu" ? "CPU capacity" : "Memory capacity"}</strong>
        </div>
        <span className="capacity-copy">
          {allocationLabel(allocated, metric)} / {allocationLabel(capacity, metric)}
        </span>
      </header>
      <div className="capacity-bar" role="img" aria-label={`${title} ${metric} allocation`}>
        {activeWorkers.map((worker) => {
          const value = allocationFor(worker, metric);
          return (
            <div
              className={`worker-segment ${workerColor(worker)}`}
              key={`${metric}-${worker.id}`}
              style={{ flexGrow: value }}
              title={`${worker.id}: ${allocationLabel(value, metric)}`}
            >
              <span>{worker.id}</span>
              <small>{allocationLabel(value, metric)}</small>
            </div>
          );
        })}
        {free > 0 && (
          <div className="worker-segment free" style={{ flexGrow: free }} title={`Unassigned: ${allocationLabel(free, metric)}`}>
            <span>FREE</span>
            <small>{allocationLabel(free, metric)}</small>
          </div>
        )}
      </div>
    </section>
  );
}

function WorkerCard({
  worker,
  gpuOwner,
  disabled,
  onToggle,
  onGpu,
  gpuAllowed
}: {
  worker: Worker;
  gpuOwner: string | null;
  disabled: boolean;
  onToggle: (worker: Worker) => void;
  onGpu: (worker: Worker) => void;
  gpuAllowed: boolean;
}) {
  const running = worker.status !== "stopped";
  const ownsGpu = gpuOwner === worker.id;
  const canUseGpu = gpuAllowed && worker.kind === "workspace" && running;

  return (
    <article className={`worker-card ${workerColor(worker)} ${running ? "assigned" : "idle"}`}>
      <header>
        <div className="worker-identity">
          <span className="worker-token">{worker.id}</span>
          <div>
            <strong>{worker.kind === "persistent" ? "Persistent worker" : "Workspace worker"}</strong>
            <small>{running ? "Placed in capacity" : "Waiting for allocation"}</small>
          </div>
        </div>
        <span className={`worker-status ${worker.status}`}>{worker.status.replace("_", " ")}</span>
      </header>

      <div className="worker-specs">
        <div>
          <span>CPU</span>
          <strong>{running ? worker.allocation.cpu_threads : "—"}</strong>
          <small>threads</small>
        </div>
        <div>
          <span>RAM</span>
          <strong>{running ? formatGiB(worker.allocation.memory_mib) : "—"}</strong>
          <small>{running ? `${formatGiB(worker.memory_used_mib)} used` : "unassigned"}</small>
        </div>
        <div>
          <span>GPU</span>
          <strong>{ownsGpu ? "Reserved" : "—"}</strong>
          <small>{ownsGpu ? worker.allocation.gpu : "not assigned"}</small>
        </div>
      </div>

      {worker.last_error && <p className="worker-error">{worker.last_error}</p>}

      <footer>
        <button className="button secondary" disabled={disabled} onClick={() => onToggle(worker)}>
          {running ? "Remove" : "Assign"}
        </button>
        {canUseGpu && (
          <button className={`button ${ownsGpu ? "danger" : "primary"}`} disabled={disabled} onClick={() => onGpu(worker)}>
            {ownsGpu ? "Release GPU" : "Attach GPU"}
          </button>
        )}
      </footer>
    </article>
  );
}

export function App() {
  const [snapshot, setSnapshot] = useState<SystemSnapshot | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const refresh = useCallback(async (showError = false) => {
    try {
      const next = await command<SystemSnapshot>("get_snapshot");
      setSnapshot(next);
      setError(null);
    } catch (reason) {
      setSnapshot(null);
      if (showError) setError(String(reason));
    }
  }, []);

  useEffect(() => {
    void refresh(true);
    const timer = window.setInterval(() => void refresh(false), 2500);
    return () => window.clearInterval(timer);
  }, [refresh]);

  useEffect(() => {
    if (!notice) return;
    const timer = window.setTimeout(() => setNotice(null), 2600);
    return () => window.clearTimeout(timer);
  }, [notice]);

  const mutate = useCallback(async (action: () => Promise<SystemSnapshot>, success: string) => {
    if (busy) return;
    setBusy(true);
    try {
      setSnapshot(await action());
      setError(null);
      setNotice(success);
    } catch (reason) {
      setError(String(reason));
    } finally {
      setBusy(false);
    }
  }, [busy]);

  const persistentWorkers = useMemo(
    () => snapshot?.slots.filter((worker) => worker.kind === "persistent") ?? [],
    [snapshot]
  );
  const workspaceWorkers = useMemo(
    () => snapshot?.slots.filter((worker) => worker.kind === "workspace") ?? [],
    [snapshot]
  );
  const activeWorkspaceCount = workspaceWorkers.filter((worker) => worker.status !== "stopped").length;
  const persistentPool = snapshot?.pools.find((pool) => pool.id === "persistent");
  const workspacePool = snapshot?.pools.find((pool) => pool.id === "workspace");

  if (!snapshot) {
    return (
      <main className="offline-screen">
        <section className="offline-panel">
          <div className="app-mark">L</div>
          <span className="eyebrow">SERVICE OFFLINE</span>
          <h1>Worker fabricに接続できません</h1>
          <p>Mock serviceを起動するか、Windows serviceの状態を確認してください。</p>
          {error && <code>{error}</code>}
          <button className="button primary" onClick={() => void refresh(true)}>再接続</button>
          <small>powershell -ExecutionPolicy Bypass -File scripts/run-demo.ps1</small>
        </section>
      </main>
    );
  }

  const updated = new Date(snapshot.updated_at_unix_ms).toLocaleTimeString("ja-JP", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit"
  });

  return (
    <div className={`app-shell ${busy ? "is-busy" : ""}`}>
      <aside className="sidebar">
        <div className="brand">
          <div className="app-mark">L</div>
          <div>
            <strong>Liaison</strong>
            <small>worker fabric</small>
          </div>
        </div>

        <nav className="sidebar-nav" aria-label="Primary navigation">
          <button className="active">Allocation</button>
          <button disabled>Workers</button>
          <button disabled>Network</button>
          <button disabled>Settings</button>
        </nav>

        <div className="sidebar-status">
          <div>
            <StatusDot online={snapshot.service_online} />
            <span>Service</span>
            <strong>{snapshot.runtime}</strong>
          </div>
          <div>
            <StatusDot online={snapshot.tailscale_online} />
            <span>Tailscale</span>
            <strong>{snapshot.tailscale_online ? "online" : "offline"}</strong>
          </div>
        </div>
      </aside>

      <main className="workspace">
        <header className="topbar">
          <div>
            <span className="eyebrow">RESOURCE ORCHESTRATION</span>
            <h1>Worker allocation</h1>
            <p>割り当て可能なスペックへworkerを配置し、容量の使われ方を直接確認します。</p>
          </div>
          <div className="sync-state">
            <StatusDot online />
            <span>Updated {updated}</span>
            <button className="icon-button" disabled={busy} onClick={() => void refresh(true)} aria-label="Refresh">↻</button>
          </div>
        </header>

        <section className="mode-panel">
          <div className="section-copy">
            <span className="eyebrow">POLICY</span>
            <h2>{MODES.find((mode) => mode.value === snapshot.mode)?.label}</h2>
            <p>{MODES.find((mode) => mode.value === snapshot.mode)?.description}</p>
          </div>
          <div className="mode-control">
            {MODES.map((mode) => (
              <button
                key={mode.value}
                className={snapshot.mode === mode.value ? "selected" : ""}
                disabled={busy}
                onClick={() => void mutate(
                  () => command<SystemSnapshot>("set_mode", { mode: mode.value }),
                  `${mode.label} modeへ変更しました`
                )}
              >
                {mode.label}
              </button>
            ))}
          </div>
        </section>

        <section className="metrics-grid">
          <MetricCard label="HOST CPU" value={formatPercent(snapshot.host.cpu_percent)} detail="physical host utilization" progress={snapshot.host.cpu_percent} />
          <MetricCard label="HOST MEMORY" value={formatGiB(snapshot.host.memory_used_mib)} detail={`${formatGiB(snapshot.host.memory_total_mib)} installed`} progress={(snapshot.host.memory_used_mib / Math.max(1, snapshot.host.memory_total_mib)) * 100} />
          <MetricCard label="GPU LOAD" value={snapshot.gpu.available ? formatPercent(snapshot.gpu.utilization_percent) : "N/A"} detail={snapshot.gpu.reserved_by ? `attached to ${snapshot.gpu.reserved_by}` : "not assigned"} progress={snapshot.gpu.utilization_percent} />
          <MetricCard label="ACTIVE WORKERS" value={`${activeWorkspaceCount} / ${workspaceWorkers.length}`} detail="workspace workers in capacity" progress={(activeWorkspaceCount / Math.max(1, workspaceWorkers.length)) * 100} />
        </section>

        <section className="fabric-panel">
          <header className="fabric-heading">
            <div>
              <span className="eyebrow">CAPACITY BOARD</span>
              <h2>Worker placement</h2>
              <p>各四角はworkerです。幅は現在割り当てられているCPUまたはRAMの比率を表します。</p>
            </div>
            <div className="worker-count-control" aria-label="Workspace worker count">
              <span>Workers</span>
              <div>
                {[0, 1, 2, 3, 4, 5].map((count) => (
                  <button
                    key={count}
                    className={activeWorkspaceCount === count ? "selected" : ""}
                    disabled={busy || snapshot.mode === "local_exclusive" || snapshot.mode === "maintenance"}
                    onClick={() => void mutate(
                      () => command<SystemSnapshot>("rebalance", { activeWorkspaceSlots: count }),
                      `${count} workerへ再配置しました`
                    )}
                  >
                    {count}
                  </button>
                ))}
              </div>
            </div>
          </header>

          {persistentPool && (
            <div className="pool-group">
              <div className="pool-label">
                <strong>Persistent capacity</strong>
                <span>P1 / P2</span>
              </div>
              <ResourceTrack title="PERSISTENT POOL" metric="cpu" pool={persistentPool} workers={persistentWorkers} />
              <ResourceTrack title="PERSISTENT POOL" metric="memory" pool={persistentPool} workers={persistentWorkers} />
            </div>
          )}

          {workspacePool && (
            <div className="pool-group featured">
              <div className="pool-label">
                <strong>Workspace capacity</strong>
                <span>W1 – W5</span>
              </div>
              <ResourceTrack title="WORKSPACE POOL" metric="cpu" pool={workspacePool} workers={workspaceWorkers} />
              <ResourceTrack title="WORKSPACE POOL" metric="memory" pool={workspacePool} workers={workspaceWorkers} />
            </div>
          )}
        </section>

        <section className="workers-section">
          <header className="section-heading">
            <div>
              <span className="eyebrow">WORKERS</span>
              <h2>Assigned units</h2>
            </div>
            <span>{snapshot.gpu.reserved_by ? `GPU → ${snapshot.gpu.reserved_by}` : "GPU unassigned"}</span>
          </header>
          <div className="worker-grid">
            {[...persistentWorkers, ...workspaceWorkers].map((worker) => (
              <WorkerCard
                key={worker.id}
                worker={worker}
                gpuOwner={snapshot.gpu.reserved_by}
                disabled={busy || (worker.status === "stopped" && (snapshot.mode === "maintenance" || (worker.kind === "workspace" && snapshot.mode === "local_exclusive")))}
                gpuAllowed={snapshot.mode === "remote"}
                onToggle={(target) => void mutate(
                  () => command<SystemSnapshot>(target.status === "stopped" ? "start_slot" : "stop_slot", { slotId: target.id }),
                  `${target.id}を${target.status === "stopped" ? "配置" : "解除"}しました`
                )}
                onGpu={(target) => void mutate(
                  () => snapshot.gpu.reserved_by === target.id
                    ? command<SystemSnapshot>("release_gpu")
                    : command<SystemSnapshot>("reserve_gpu", { slotId: target.id, access: "exclusive" }),
                  snapshot.gpu.reserved_by === target.id ? "GPUを解放しました" : `GPUを${target.id}へ割り当てました`
                )}
              />
            ))}
          </div>
        </section>
      </main>

      {notice && <div className="toast success">{notice}</div>}
      {error && <div className="toast error" onClick={() => setError(null)}>{error}</div>}
    </div>
  );
}
