import { invoke } from "@tauri-apps/api/core";
import React, { useCallback, useEffect, useMemo, useState } from "react";
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

const modeNames: Record<Mode, string> = {
  remote: "Remote",
  class: "Class",
  local_exclusive: "Local exclusive",
  maintenance: "Maintenance"
};

const formatGiB = (mib: number): string => `${(mib / 1024).toFixed(mib < 10240 ? 1 : 0)} GB`;
const isActive = (slot: SlotSummary): boolean => slot.status !== "stopped";

async function call<T>(command: string, args: Record<string, unknown> = {}): Promise<T> {
  return invoke<T>(command, args);
}

function App(): React.JSX.Element {
  const [snapshot, setSnapshot] = useState<SystemSnapshot | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
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
    if (busy) return;
    setBusy(true);
    try {
      setSnapshot(await action());
      setError(null);
    } catch (reason) {
      setError(String(reason));
    } finally {
      setBusy(false);
    }
  };

  const workers = useMemo(
    () => snapshot?.slots.filter((slot) => slot.kind === "workspace") ?? [],
    [snapshot]
  );
  const activeWorkers = workers.filter(isActive);
  const persistent = snapshot?.slots.filter((slot) => slot.kind === "persistent") ?? [];
  const workspacePool = snapshot?.pools.find((pool) => pool.id === "workspace");

  if (!snapshot) {
    return (
      <main className="center-screen">
        <section className="dialog-card">
          <div className="mark">L</div>
          <p className="eyebrow">LOCAL SERVICE</p>
          <h1>{error ? "Service unavailable" : "Connecting to Liaison"}</h1>
          <p>{error ?? "Reading the current workstation allocation."}</p>
          <button onClick={() => void refresh()}>Retry</button>
        </section>
      </main>
    );
  }

  const nextWorkerCount = Math.min(activeWorkers.length + 1, workers.length);
  const updated = new Date(snapshot.updated_at_unix_ms).toLocaleTimeString("ja-JP");

  return (
    <div className={`shell ${busy ? "is-busy" : ""}`}>
      <header className="app-header">
        <div className="brand-row">
          <div className="mark">L</div>
          <div>
            <strong>Liaison</strong>
            <span>worker allocator</span>
          </div>
        </div>
        <div className="header-meta">
          <span className={snapshot.tailscale_online ? "online" : "offline"}>
            {snapshot.tailscale_online ? "Network online" : "Network offline"}
          </span>
          <span>{snapshot.runtime}</span>
          <span>updated {updated}</span>
          <button className="ghost" onClick={() => void refresh()}>Refresh</button>
        </div>
      </header>

      <main className="content">
        <section className="top-grid">
          <div>
            <p className="eyebrow">WORKSTATION CAPACITY</p>
            <h1>Assign workers to the available machine.</h1>
            <p className="lead">
              Each worker is fitted into the shared capacity. Adding or removing one recalculates the CPU and memory assigned to every active worker.
            </p>
          </div>
          <div className="mode-control">
            {(Object.keys(modeNames) as Mode[]).map((mode) => (
              <button
                key={mode}
                className={snapshot.mode === mode ? "selected" : ""}
                onClick={() => void run(() => call("set_mode", { mode }))}
              >
                {modeNames[mode]}
              </button>
            ))}
          </div>
        </section>

        {error && <div className="error-banner">{error}</div>}

        <section className="capacity-card">
          <div className="capacity-heading">
            <div>
              <p className="eyebrow">SHARED WORKER POOL</p>
              <h2>{activeWorkers.length} workers fitted</h2>
            </div>
            <div className="capacity-total">
              <strong>{workspacePool?.cpu_capacity_threads ?? 0}</strong><span>CPU threads</span>
              <strong>{formatGiB(workspacePool?.memory_capacity_mib ?? 0)}</strong><span>memory</span>
            </div>
          </div>

          <div className="resource-rail" aria-label="Worker allocation rail">
            {activeWorkers.length === 0 ? (
              <div className="empty-rail">No workers assigned</div>
            ) : activeWorkers.map((worker) => {
              const width = workspacePool && workspacePool.cpu_capacity_threads > 0
                ? (worker.allocation.cpu_threads / workspacePool.cpu_capacity_threads) * 100
                : 0;
              return (
                <article className="worker-block" style={{ width: `${width}%` }} key={worker.id}>
                  <div className="worker-block-head">
                    <strong>{worker.id}</strong>
                    <span>{worker.status}</span>
                  </div>
                  <div className="worker-spec">
                    <b>{worker.allocation.cpu_threads}</b> threads
                    <b>{formatGiB(worker.allocation.memory_mib)}</b> RAM
                  </div>
                  {snapshot.gpu.reserved_by === worker.id && <span className="gpu-badge">GPU</span>}
                </article>
              );
            })}
          </div>

          <div className="rail-actions">
            <button
              className="primary"
              disabled={activeWorkers.length >= workers.length || snapshot.mode === "local_exclusive" || snapshot.mode === "maintenance"}
              onClick={() => void run(() => call("rebalance", { activeWorkspaceSlots: nextWorkerCount }))}
            >
              Add worker
            </button>
            <button
              disabled={activeWorkers.length === 0}
              onClick={() => void run(() => call("rebalance", { activeWorkspaceSlots: Math.max(0, activeWorkers.length - 1) }))}
            >
              Remove worker
            </button>
            <span>Allocation is proportional to the currently available pool.</span>
          </div>
        </section>

        <section className="detail-grid">
          <div className="panel">
            <div className="panel-heading"><div><p className="eyebrow">WORKERS</p><h2>Assigned units</h2></div></div>
            <div className="worker-list">
              {workers.map((worker) => (
                <article className={`worker-row ${isActive(worker) ? "active" : ""}`} key={worker.id}>
                  <div className="worker-id"><strong>{worker.id}</strong><span>{worker.status}</span></div>
                  <div className="mini-spec"><span>CPU <b>{worker.allocation.cpu_threads || "—"}</b></span><span>RAM <b>{worker.allocation.memory_mib ? formatGiB(worker.allocation.memory_mib) : "—"}</b></span></div>
                  <div className="row-actions">
                    {isActive(worker) && (
                      <button onClick={() => void run(() => call("reserve_gpu", { slotId: worker.id, access: "exclusive" }))}>
                        {snapshot.gpu.reserved_by === worker.id ? "GPU assigned" : "Assign GPU"}
                      </button>
                    )}
                    <button onClick={() => void run(() => call(isActive(worker) ? "stop_slot" : "start_slot", { slotId: worker.id }))}>
                      {isActive(worker) ? "Stop" : "Start"}
                    </button>
                  </div>
                </article>
              ))}
            </div>
          </div>

          <aside className="side-stack">
            <section className="panel">
              <p className="eyebrow">HOST LOAD</p>
              <div className="host-metric"><span>CPU</span><strong>{snapshot.host.cpu_percent.toFixed(0)}%</strong></div>
              <div className="meter"><i style={{ width: `${snapshot.host.cpu_percent}%` }} /></div>
              <div className="host-metric"><span>Memory</span><strong>{formatGiB(snapshot.host.memory_used_mib)} / {formatGiB(snapshot.host.memory_total_mib)}</strong></div>
              <div className="meter"><i style={{ width: `${(snapshot.host.memory_used_mib / snapshot.host.memory_total_mib) * 100}%` }} /></div>
            </section>
            <section className="panel">
              <p className="eyebrow">PERSISTENT LAYER</p>
              {persistent.map((slot) => <div className="persistent-row" key={slot.id}><strong>{slot.id}</strong><span>{slot.status}</span><small>{slot.allocation.cpu_threads} threads · {formatGiB(slot.allocation.memory_mib)}</small></div>)}
            </section>
          </aside>
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
