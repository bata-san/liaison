import { invoke } from "@tauri-apps/api/core";
import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
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
  slots: SlotSummary[];
  updated_at_unix_ms: number;
}

interface ResourceSegment {
  id: string;
  kind: SlotKind;
  value: number;
  detail: string;
}

const modeNames: Record<Mode, string> = {
  remote: "Remote",
  class: "Class",
  local_exclusive: "Local exclusive",
  maintenance: "Maintenance"
};

const modeDescriptions: Record<Mode, string> = {
  remote: "Full worker pool with shared or exclusive GPU access.",
  class: "Reduced worker capacity while Windows remains available for class use.",
  local_exclusive: "Workers stop. Persistent services continue running.",
  maintenance: "All managed slots stop for host maintenance."
};

const gpuNames: Record<GpuAccess, string> = {
  none: "No GPU",
  shared: "Shared GPU",
  exclusive: "Exclusive GPU"
};

const formatGiB = (mib: number): string => `${(mib / 1024).toFixed(mib < 10_240 ? 1 : 0)} GB`;
const isActive = (slot: SlotSummary): boolean => slot.status !== "stopped";
const clamp = (value: number, minimum: number, maximum: number): number =>
  Math.min(maximum, Math.max(minimum, value));

async function call<T>(command: string, args: Record<string, unknown> = {}): Promise<T> {
  return invoke<T>(command, args);
}

function ResourceLane({
  label,
  total,
  allocated,
  unit,
  segments
}: {
  label: string;
  total: number;
  allocated: number;
  unit: string;
  segments: ResourceSegment[];
}): React.JSX.Element {
  const free = Math.max(0, total - allocated);
  return (
    <section className="resource-lane">
      <header>
        <div>
          <p className="lane-label">{label}</p>
          <strong>{allocated} / {total} {unit}</strong>
        </div>
        <span>{total > 0 ? `${Math.round((allocated / total) * 100)}% assigned` : "Unavailable"}</span>
      </header>
      <div className="resource-track">
        {segments.map((segment) => (
          <div
            className={`resource-segment ${segment.kind}`}
            key={`${label}-${segment.id}`}
            style={{ width: `${total > 0 ? (segment.value / total) * 100 : 0}%` }}
            title={`${segment.id}: ${segment.detail}`}
          >
            <strong>{segment.id}</strong>
            <small>{segment.detail}</small>
          </div>
        ))}
        {free > 0 && (
          <div
            className="resource-segment free"
            style={{ width: `${total > 0 ? (free / total) * 100 : 100}%` }}
          >
            <strong>Free</strong>
            <small>{free} {unit}</small>
          </div>
        )}
      </div>
    </section>
  );
}

function GpuLane({
  available,
  workers
}: {
  available: boolean;
  workers: SlotSummary[];
}): React.JSX.Element {
  const assigned = workers.filter((worker) => isActive(worker) && worker.allocation.gpu !== "none");
  const exclusive = assigned.find((worker) => worker.allocation.gpu === "exclusive");
  return (
    <section className="resource-lane">
      <header>
        <div>
          <p className="lane-label">GPU access</p>
          <strong>{available ? (exclusive ? `Exclusive · ${exclusive.id}` : `${assigned.length} shared`) : "Unavailable"}</strong>
        </div>
        <span>Access policy, not VRAM partitioning</span>
      </header>
      <div className="resource-track gpu-track">
        {!available || assigned.length === 0 ? (
          <div className="resource-segment free full">
            <strong>{available ? "GPU free" : "GPU unavailable"}</strong>
            <small>{available ? "No worker has device access" : "nvidia-smi did not respond"}</small>
          </div>
        ) : exclusive ? (
          <div className="resource-segment workspace full exclusive">
            <strong>{exclusive.id}</strong>
            <small>Exclusive access</small>
          </div>
        ) : (
          assigned.map((worker) => (
            <div
              className="resource-segment workspace shared"
              key={`gpu-${worker.id}`}
              style={{ width: `${100 / assigned.length}%` }}
            >
              <strong>{worker.id}</strong>
              <small>Shared access</small>
            </div>
          ))
        )}
      </div>
    </section>
  );
}

function WorkerEditor({
  worker,
  maximumCpu,
  maximumMemoryMib,
  mode,
  busy,
  onApply,
  onStop
}: {
  worker: SlotSummary;
  maximumCpu: number;
  maximumMemoryMib: number;
  mode: Mode;
  busy: boolean;
  onApply: (slotId: string, cpuThreads: number, memoryMib: number, gpu: GpuAccess) => void;
  onStop: (slotId: string) => void;
}): React.JSX.Element {
  const active = isActive(worker);
  const [cpuThreads, setCpuThreads] = useState(String(worker.allocation.cpu_threads || Math.min(4, maximumCpu)));
  const [memoryGiB, setMemoryGiB] = useState(
    String(worker.allocation.memory_mib ? worker.allocation.memory_mib / 1024 : Math.min(4, maximumMemoryMib / 1024))
  );
  const [gpu, setGpu] = useState<GpuAccess>(worker.allocation.gpu);

  useEffect(() => {
    if (active) {
      setCpuThreads(String(worker.allocation.cpu_threads));
      setMemoryGiB(String(worker.allocation.memory_mib / 1024));
      setGpu(worker.allocation.gpu);
    }
  }, [
    active,
    worker.allocation.cpu_threads,
    worker.allocation.memory_mib,
    worker.allocation.gpu
  ]);

  const parsedCpu = Number(cpuThreads);
  const parsedMemoryMib = Math.round(Number(memoryGiB) * 1024);
  const valid =
    Number.isFinite(parsedCpu)
    && Number.isInteger(parsedCpu)
    && parsedCpu >= 1
    && parsedCpu <= maximumCpu
    && Number.isFinite(parsedMemoryMib)
    && parsedMemoryMib >= 512
    && parsedMemoryMib <= maximumMemoryMib;
  const disabledByMode = mode === "local_exclusive" || mode === "maintenance";

  return (
    <article className={`worker-editor ${active ? "active" : ""}`}>
      <header className="worker-heading">
        <div>
          <span className={`status-dot ${worker.status}`} />
          <div>
            <h3>{worker.id}</h3>
            <p>{active ? worker.status : "Ready to assign"}</p>
          </div>
        </div>
        {active && <span className="allocation-summary">{worker.allocation.cpu_threads} CPU · {formatGiB(worker.allocation.memory_mib)}</span>}
      </header>

      <div className="editor-grid">
        <label>
          <span>CPU threads</span>
          <input
            type="number"
            min="1"
            max={maximumCpu}
            step="1"
            value={cpuThreads}
            onChange={(event) => setCpuThreads(event.currentTarget.value)}
          />
          <input
            aria-label={`${worker.id} CPU slider`}
            type="range"
            min="1"
            max={Math.max(1, maximumCpu)}
            step="1"
            value={clamp(Number(cpuThreads) || 1, 1, Math.max(1, maximumCpu))}
            onChange={(event) => setCpuThreads(event.currentTarget.value)}
          />
        </label>

        <label>
          <span>Memory</span>
          <div className="input-with-unit">
            <input
              type="number"
              min="0.5"
              max={Math.max(0.5, maximumMemoryMib / 1024)}
              step="0.5"
              value={memoryGiB}
              onChange={(event) => setMemoryGiB(event.currentTarget.value)}
            />
            <b>GB</b>
          </div>
          <input
            aria-label={`${worker.id} memory slider`}
            type="range"
            min="0.5"
            max={Math.max(0.5, maximumMemoryMib / 1024)}
            step="0.5"
            value={clamp(Number(memoryGiB) || 0.5, 0.5, Math.max(0.5, maximumMemoryMib / 1024))}
            onChange={(event) => setMemoryGiB(event.currentTarget.value)}
          />
        </label>

        <label>
          <span>GPU</span>
          <select
            value={mode === "remote" ? gpu : "none"}
            disabled={mode !== "remote"}
            onChange={(event) => setGpu(event.currentTarget.value as GpuAccess)}
          >
            {(Object.keys(gpuNames) as GpuAccess[]).map((access) => (
              <option value={access} key={access}>{gpuNames[access]}</option>
            ))}
          </select>
          <small>{mode === "remote" ? "Shared can be used by multiple workers." : "GPU is disabled outside Remote mode."}</small>
        </label>
      </div>

      {worker.last_error && <p className="worker-error">{worker.last_error}</p>}

      <footer className="worker-actions">
        <span>Maximum now: {maximumCpu} CPU · {formatGiB(maximumMemoryMib)}</span>
        <div>
          {active && (
            <button className="secondary-button" disabled={busy} onClick={() => onStop(worker.id)}>
              Stop
            </button>
          )}
          <button
            className="primary-button"
            disabled={busy || disabledByMode || !valid}
            onClick={() => onApply(worker.id, parsedCpu, parsedMemoryMib, mode === "remote" ? gpu : "none")}
          >
            {active ? "Apply allocation" : "Assign worker"}
          </button>
        </div>
      </footer>
    </article>
  );
}

function App(): React.JSX.Element {
  const [snapshot, setSnapshot] = useState<SystemSnapshot | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const busyRef = useRef(false);

  const refresh = useCallback(async () => {
    if (busyRef.current) return;
    try {
      setSnapshot(await call<SystemSnapshot>("get_snapshot"));
      setError(null);
    } catch (reason) {
      setError(String(reason));
    }
  }, []);

  useEffect(() => {
    void refresh();
    const timer = window.setInterval(() => void refresh(), 2500);
    return () => window.clearInterval(timer);
  }, [refresh]);

  const run = async (action: () => Promise<SystemSnapshot>): Promise<void> => {
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy(true);
    try {
      setSnapshot(await action());
      setError(null);
    } catch (reason) {
      setError(String(reason));
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  };

  const slots = snapshot?.slots ?? [];
  const workers = useMemo(() => slots.filter((slot) => slot.kind === "workspace"), [slots]);
  const persistent = useMemo(() => slots.filter((slot) => slot.kind === "persistent"), [slots]);
  const activeWorkers = workers.filter(isActive);
  const activePersistent = persistent.filter(isActive);
  const workspacePool = snapshot?.pools.find((pool) => pool.id === "workspace");
  const persistentPool = snapshot?.pools.find((pool) => pool.id === "persistent");

  if (!snapshot || !workspacePool || !persistentPool) {
    return (
      <main className="center-screen">
        <section className="dialog-card">
          <div className="mark">L</div>
          <p className="eyebrow">LOCAL SERVICE</p>
          <h1>{error ? "Service unavailable" : "Connecting to Liaison"}</h1>
          <p>{error ?? "Reading the managed workstation capacity."}</p>
          <button className="primary-button" onClick={() => void refresh()}>Retry</button>
        </section>
      </main>
    );
  }

  const totalCpu = persistentPool.cpu_capacity_threads + workspacePool.cpu_capacity_threads;
  const totalMemory = persistentPool.memory_capacity_mib + workspacePool.memory_capacity_mib;
  const allocatedCpu = persistentPool.cpu_allocated_threads + workspacePool.cpu_allocated_threads;
  const allocatedMemory = persistentPool.memory_allocated_mib + workspacePool.memory_allocated_mib;
  const cpuSegments: ResourceSegment[] = [...activePersistent, ...activeWorkers].map((slot) => ({
    id: slot.id,
    kind: slot.kind,
    value: slot.allocation.cpu_threads,
    detail: `${slot.allocation.cpu_threads} threads`
  }));
  const memorySegments: ResourceSegment[] = [...activePersistent, ...activeWorkers].map((slot) => ({
    id: slot.id,
    kind: slot.kind,
    value: slot.allocation.memory_mib,
    detail: formatGiB(slot.allocation.memory_mib)
  }));
  const updated = new Date(snapshot.updated_at_unix_ms).toLocaleTimeString("ja-JP", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit"
  });

  const applyWorker = (slotId: string, cpuThreads: number, memoryMib: number, gpu: GpuAccess): void => {
    void run(() => call<SystemSnapshot>("assign_worker", {
      slotId,
      cpuThreads,
      memoryMib,
      gpu
    }));
  };

  return (
    <div className={`shell ${busy ? "is-busy" : ""}`}>
      <nav className="global-nav">
        <div className="nav-inner">
          <div className="brand-row">
            <div className="mark">L</div>
            <strong>Liaison</strong>
          </div>
          <div className="nav-status">
            <span>{snapshot.runtime}</span>
            <span className={snapshot.tailscale_online ? "online" : "offline"}>
              {snapshot.tailscale_online ? "Network online" : "Network offline"}
            </span>
          </div>
        </div>
      </nav>

      <div className="sub-nav">
        <div className="sub-nav-inner">
          <div>
            <strong>Worker allocation</strong>
            <span>Service v{snapshot.service_version}</span>
          </div>
          <div>
            <span>Updated {updated}</span>
            <button className="utility-button" onClick={() => void refresh()}>Refresh</button>
          </div>
        </div>
      </div>

      <main>
        <section className="hero-section">
          <div className="hero-copy">
            <p className="eyebrow">MANAGED WORKSTATION</p>
            <h1>Fit each worker to the machine.</h1>
            <p className="hero-lead">
              Choose CPU, memory, and GPU access for every worker. Persistent services remain visible in the same capacity map, so the full managed footprint is always accounted for.
            </p>
          </div>
          <div className="mode-panel">
            <p className="eyebrow">OPERATING MODE</p>
            <div className="mode-control">
              {(Object.keys(modeNames) as Mode[]).map((mode) => (
                <button
                  key={mode}
                  className={snapshot.mode === mode ? "selected" : ""}
                  disabled={busy}
                  onClick={() => void run(() => call<SystemSnapshot>("set_mode", { mode }))}
                >
                  {modeNames[mode]}
                </button>
              ))}
            </div>
            <p>{modeDescriptions[snapshot.mode]}</p>
          </div>
        </section>

        {error && <div className="error-banner">{error}</div>}

        <section className="capacity-section">
          <header className="section-heading">
            <div>
              <p className="eyebrow">CAPACITY MAP</p>
              <h2>{activePersistent.length + activeWorkers.length} active units</h2>
            </div>
            <div className="capacity-summary">
              <div><strong>{allocatedCpu}</strong><span>of {totalCpu} CPU</span></div>
              <div><strong>{formatGiB(allocatedMemory)}</strong><span>of {formatGiB(totalMemory)} RAM</span></div>
              <div><strong>{activeWorkers.length}</strong><span>workers</span></div>
            </div>
          </header>

          <div className="lane-stack">
            <ResourceLane
              label="CPU"
              total={totalCpu}
              allocated={allocatedCpu}
              unit="threads"
              segments={cpuSegments}
            />
            <ResourceLane
              label="Memory"
              total={totalMemory}
              allocated={allocatedMemory}
              unit="MiB"
              segments={memorySegments}
            />
            <GpuLane available={snapshot.gpu.available} workers={workers} />
          </div>

          <div className="legend">
            <span><i className="persistent-key" />Persistent layer</span>
            <span><i className="worker-key" />Worker</span>
            <span><i className="free-key" />Unassigned</span>
          </div>
        </section>

        <section className="workers-section">
          <header className="section-heading">
            <div>
              <p className="eyebrow">WORKERS</p>
              <h2>Custom allocations</h2>
            </div>
            <p className="section-note">
              CPU and memory must remain inside the workspace pool: {workspacePool.cpu_capacity_threads} threads and {formatGiB(workspacePool.memory_capacity_mib)}.
            </p>
          </header>

          <div className="worker-editor-list">
            {workers.map((worker) => {
              const otherCpu = activeWorkers
                .filter((candidate) => candidate.id !== worker.id)
                .reduce((sum, candidate) => sum + candidate.allocation.cpu_threads, 0);
              const otherMemory = activeWorkers
                .filter((candidate) => candidate.id !== worker.id)
                .reduce((sum, candidate) => sum + candidate.allocation.memory_mib, 0);
              return (
                <WorkerEditor
                  worker={worker}
                  maximumCpu={Math.max(0, workspacePool.cpu_capacity_threads - otherCpu)}
                  maximumMemoryMib={Math.max(0, workspacePool.memory_capacity_mib - otherMemory)}
                  mode={snapshot.mode}
                  busy={busy}
                  onApply={applyWorker}
                  onStop={(slotId) => void run(() => call<SystemSnapshot>("stop_slot", { slotId }))}
                  key={worker.id}
                />
              );
            })}
          </div>
        </section>

        <section className="status-section">
          <div>
            <p className="eyebrow">PERSISTENT LAYER</p>
            <h2>Included in managed capacity</h2>
            <div className="persistent-grid">
              {persistent.map((slot) => (
                <article key={slot.id}>
                  <div>
                    <strong>{slot.id}</strong>
                    <span>{slot.status}</span>
                  </div>
                  <p>{slot.allocation.cpu_threads || 0} CPU · {formatGiB(slot.allocation.memory_mib)}</p>
                </article>
              ))}
            </div>
          </div>
          <div className="host-card">
            <p className="eyebrow">LIVE HOST</p>
            <div className="host-stat">
              <span>CPU load</span>
              <strong>{snapshot.host.cpu_percent.toFixed(0)}%</strong>
            </div>
            <div className="thin-meter"><i style={{ width: `${clamp(snapshot.host.cpu_percent, 0, 100)}%` }} /></div>
            <div className="host-stat">
              <span>Memory used</span>
              <strong>{formatGiB(snapshot.host.memory_used_mib)}</strong>
            </div>
            <div className="thin-meter">
              <i style={{ width: `${snapshot.host.memory_total_mib > 0 ? clamp((snapshot.host.memory_used_mib / snapshot.host.memory_total_mib) * 100, 0, 100) : 0}%` }} />
            </div>
            <div className="host-stat">
              <span>GPU load</span>
              <strong>{snapshot.gpu.available ? `${snapshot.gpu.utilization_percent.toFixed(0)}%` : "N/A"}</strong>
            </div>
          </div>
        </section>
      </main>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
