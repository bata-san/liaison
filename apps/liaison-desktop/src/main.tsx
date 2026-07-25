import { invoke } from "@tauri-apps/api/core";
import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { Group, Panel, Separator } from "react-resizable-panels";
import "./styles.css";

type Mode = "remote" | "class" | "local_exclusive" | "maintenance";
type SlotKind = "persistent" | "workspace";
type SlotStatus = "stopped" | "starting" | "running" | "throttled" | "draining" | "error";
type GpuAccess = "none" | "shared" | "exclusive";
type WeightMap = Record<string, number>;

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

interface PlannedWorker {
  id: string;
  allocation: Allocation;
}

const MIN_WORKER_CPU = 1;
const MIN_WORKER_MEMORY_MIB = 512;
const MIN_PANEL_PERCENT = 5;

const modeLabels: Record<Mode, string> = {
  remote: "Remote",
  class: "Class",
  local_exclusive: "Local",
  maintenance: "Maint."
};

const gpuLabels: Record<GpuAccess, string> = {
  none: "GPU off",
  shared: "GPU shared",
  exclusive: "GPU exclusive"
};

const isActive = (slot: SlotSummary): boolean => slot.status !== "stopped";
const formatGiB = (mib: number): string => {
  const value = mib / 1024;
  return `${Number.isInteger(value) ? value.toFixed(0) : value.toFixed(1)} GB`;
};

async function call<T>(command: string, args: Record<string, unknown> = {}): Promise<T> {
  return invoke<T>(command, args);
}

function normalizeWeights(input: WeightMap, ids: string[]): WeightMap {
  if (ids.length === 0) return {};
  const values = ids.map((id) => Math.max(0, Number(input[id]) || 0));
  const total = values.reduce((sum, value) => sum + value, 0);
  if (total <= 0) {
    const equal = 100 / ids.length;
    return Object.fromEntries(ids.map((id) => [id, equal]));
  }
  return Object.fromEntries(ids.map((id, index) => [id, (values[index] / total) * 100]));
}

function equalWeights(ids: string[]): WeightMap {
  return normalizeWeights({}, ids);
}

function weightsFromSnapshot(workers: SlotSummary[]): WeightMap {
  const total = workers.reduce((sum, worker) => sum + worker.allocation.cpu_threads, 0);
  if (total <= 0) return equalWeights(workers.map((worker) => worker.id));
  return Object.fromEntries(
    workers.map((worker) => [worker.id, (worker.allocation.cpu_threads / total) * 100])
  );
}

function addWorkerWeight(current: WeightMap, existingIds: string[], newId: string): WeightMap {
  if (existingIds.length === 0) return { [newId]: 100 };
  const newShare = 100 / (existingIds.length + 1);
  const scale = (100 - newShare) / 100;
  const normalized = normalizeWeights(current, existingIds);
  return normalizeWeights(
    {
      ...Object.fromEntries(existingIds.map((id) => [id, normalized[id] * scale])),
      [newId]: newShare
    },
    [...existingIds, newId]
  );
}

function allocateWeighted(
  total: number,
  weights: WeightMap,
  ids: string[],
  minimum: number,
  quantum = 1
): Record<string, number> {
  if (ids.length === 0) return {};
  const totalUnits = Math.floor(total / quantum);
  const minimumUnits = Math.ceil(minimum / quantum);
  const distributable = Math.max(0, totalUnits - minimumUnits * ids.length);
  const normalized = normalizeWeights(weights, ids);
  const rawExtras = ids.map((id) => (normalized[id] / 100) * distributable);
  const extraUnits = rawExtras.map(Math.floor);
  let remainder = distributable - extraUnits.reduce((sum, value) => sum + value, 0);
  const order = rawExtras
    .map((value, index) => ({ index, fraction: value - Math.floor(value) }))
    .sort((left, right) => right.fraction - left.fraction);

  for (const entry of order) {
    if (remainder <= 0) break;
    extraUnits[entry.index] += 1;
    remainder -= 1;
  }

  return Object.fromEntries(
    ids.map((id, index) => [id, (minimumUnits + extraUnits[index]) * quantum])
  );
}

function planFromWeights(
  snapshot: SystemSnapshot,
  workers: SlotSummary[],
  weights: WeightMap
): PlannedWorker[] {
  const pool = snapshot.pools.find((candidate) => candidate.id === "workspace");
  if (!pool || workers.length === 0) return [];

  const ids = workers.map((worker) => worker.id);
  const cpu = allocateWeighted(pool.cpu_capacity_threads, weights, ids, MIN_WORKER_CPU);
  const memory = allocateWeighted(
    pool.memory_capacity_mib,
    weights,
    ids,
    MIN_WORKER_MEMORY_MIB,
    512
  );

  return workers.map((worker): PlannedWorker => ({
    id: worker.id,
    allocation: {
      cpu_threads: cpu[worker.id],
      memory_mib: memory[worker.id],
      gpu: worker.allocation.gpu
    }
  }));
}

function nextGpuAccess(current: GpuAccess): GpuAccess {
  if (current === "shared") return "exclusive";
  if (current === "exclusive") return "none";
  return "shared";
}

function App(): React.JSX.Element {
  const [snapshot, setSnapshot] = useState<SystemSnapshot | null>(null);
  const [weights, setWeights] = useState<WeightMap>({});
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
    const timer = window.setInterval(() => void refresh(), 3000);
    return () => window.clearInterval(timer);
  }, [refresh]);

  const run = useCallback(async (
    action: () => Promise<SystemSnapshot>
  ): Promise<SystemSnapshot | null> => {
    if (busyRef.current) return null;
    busyRef.current = true;
    setBusy(true);
    try {
      const next = await action();
      setSnapshot(next);
      setError(null);
      return next;
    } catch (reason) {
      setError(String(reason));
      return null;
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  }, []);

  const slots = snapshot?.slots ?? [];
  const persistent = useMemo(
    () => slots.filter((slot) => slot.kind === "persistent" && isActive(slot)),
    [slots]
  );
  const workers = useMemo(() => slots.filter((slot) => slot.kind === "workspace"), [slots]);
  const activeWorkers = useMemo(
    () => workers.filter(isActive).sort((left, right) => left.id.localeCompare(right.id)),
    [workers]
  );
  const activeIds = useMemo(() => activeWorkers.map((worker) => worker.id), [activeWorkers]);
  const activeKey = activeIds.join(":");
  const workspacePool = snapshot?.pools.find((pool) => pool.id === "workspace");
  const persistentPool = snapshot?.pools.find((pool) => pool.id === "persistent");
  const canAdd = workers.some((worker) => !isActive(worker))
    && snapshot !== null
    && snapshot.mode !== "local_exclusive"
    && snapshot.mode !== "maintenance";

  useEffect(() => {
    if (activeWorkers.length === 0) {
      setWeights({});
      return;
    }
    setWeights((current) => {
      const currentIds = Object.keys(current).sort().join(":");
      if (currentIds === activeKey) return normalizeWeights(current, activeIds);
      return weightsFromSnapshot(activeWorkers);
    });
  }, [activeKey, activeIds, activeWorkers]);

  const assign = useCallback((worker: PlannedWorker): Promise<SystemSnapshot> => (
    call<SystemSnapshot>("assign_worker", {
      slotId: worker.id,
      cpuThreads: worker.allocation.cpu_threads,
      memoryMib: worker.allocation.memory_mib,
      gpu: worker.allocation.gpu
    })
  ), []);

  const executePlan = useCallback(async (
    base: SystemSnapshot,
    plan: PlannedWorker[]
  ): Promise<SystemSnapshot> => {
    let current = base;
    const targetById = new Map(plan.map((worker) => [worker.id, worker]));
    const active = current.slots
      .filter((slot) => slot.kind === "workspace" && isActive(slot) && targetById.has(slot.id))
      .sort((left, right) => {
        const leftExclusive = left.allocation.gpu === "exclusive" ? -1 : 0;
        const rightExclusive = right.allocation.gpu === "exclusive" ? -1 : 0;
        return leftExclusive - rightExclusive;
      });

    for (const slot of active) {
      const target = targetById.get(slot.id);
      if (!target) continue;
      current = await assign({
        id: slot.id,
        allocation: {
          cpu_threads: MIN_WORKER_CPU,
          memory_mib: MIN_WORKER_MEMORY_MIB,
          gpu: target.allocation.gpu
        }
      });
    }

    for (const worker of plan) {
      const slot = current.slots.find((candidate) => candidate.id === worker.id);
      if (!slot || !isActive(slot)) {
        current = await assign({
          id: worker.id,
          allocation: {
            cpu_threads: MIN_WORKER_CPU,
            memory_mib: MIN_WORKER_MEMORY_MIB,
            gpu: worker.allocation.gpu
          }
        });
      }
    }

    for (const worker of plan) current = await assign(worker);
    return current;
  }, [assign]);

  const applyWeights = useCallback((
    base: SystemSnapshot,
    nextWeights: WeightMap
  ): Promise<SystemSnapshot> => {
    const active = base.slots
      .filter((slot) => slot.kind === "workspace" && isActive(slot))
      .sort((left, right) => left.id.localeCompare(right.id));
    return executePlan(base, planFromWeights(base, active, nextWeights));
  }, [executePlan]);

  const addWorker = useCallback(() => {
    if (!snapshot || !canAdd || busy) return;
    const next = workers.find((worker) => !isActive(worker));
    if (!next) return;

    const targetWeights = addWorkerWeight(normalizeWeights(weights, activeIds), activeIds, next.id);
    const defaultGpu: GpuAccess = snapshot.mode === "remote" && snapshot.gpu.available
      ? "shared"
      : "none";
    setWeights(targetWeights);

    void run(async () => {
      let current = snapshot;
      const active = current.slots
        .filter((slot) => slot.kind === "workspace" && isActive(slot))
        .sort((left, right) => {
          const leftExclusive = left.allocation.gpu === "exclusive" ? -1 : 0;
          const rightExclusive = right.allocation.gpu === "exclusive" ? -1 : 0;
          return leftExclusive - rightExclusive;
        });

      for (const worker of active) {
        current = await assign({
          id: worker.id,
          allocation: {
            cpu_threads: MIN_WORKER_CPU,
            memory_mib: MIN_WORKER_MEMORY_MIB,
            gpu: defaultGpu
          }
        });
      }

      current = await assign({
        id: next.id,
        allocation: {
          cpu_threads: MIN_WORKER_CPU,
          memory_mib: MIN_WORKER_MEMORY_MIB,
          gpu: defaultGpu
        }
      });

      const nextActive = current.slots
        .filter((slot) => slot.kind === "workspace" && isActive(slot))
        .sort((left, right) => left.id.localeCompare(right.id));
      const plan: PlannedWorker[] = planFromWeights(current, nextActive, targetWeights).map(
        (worker): PlannedWorker => ({
          ...worker,
          allocation: {
            ...worker.allocation,
            gpu: defaultGpu
          }
        })
      );
      return executePlan(current, plan);
    });
  }, [snapshot, canAdd, busy, workers, weights, activeIds, run, assign, executePlan]);

  const removeWorker = useCallback((slotId: string) => {
    if (!snapshot || busy) return;
    const remainingIds = activeIds.filter((id) => id !== slotId);
    const targetWeights = normalizeWeights(weights, remainingIds);
    setWeights(targetWeights);
    void run(async () => {
      let current = await call<SystemSnapshot>("stop_slot", { slotId });
      if (remainingIds.length > 0) current = await applyWeights(current, targetWeights);
      return current;
    });
  }, [snapshot, busy, activeIds, weights, run, applyWeights]);

  const equalize = useCallback(() => {
    if (!snapshot || busy || activeIds.length === 0) return;
    const targetWeights = equalWeights(activeIds);
    setWeights(targetWeights);
    void run(() => applyWeights(snapshot, targetWeights));
  }, [snapshot, busy, activeIds, run, applyWeights]);

  const cycleGpu = useCallback((worker: SlotSummary) => {
    if (!snapshot || busy || snapshot.mode !== "remote") return;
    const next = nextGpuAccess(worker.allocation.gpu);
    void run(() => assign({
      id: worker.id,
      allocation: { ...worker.allocation, gpu: next }
    }));
  }, [snapshot, busy, run, assign]);

  const setMode = useCallback((mode: Mode) => {
    if (!snapshot || busy || snapshot.mode === mode) return;
    void run(() => call<SystemSnapshot>("set_mode", { mode }));
  }, [snapshot, busy, run]);

  const handleLiveLayout = useCallback((layout: WeightMap) => {
    setWeights(normalizeWeights(layout, activeIds));
  }, [activeIds]);

  const handleCommittedLayout = useCallback((
    layout: WeightMap,
    meta: { isUserInteraction: boolean }
  ) => {
    if (!snapshot || busy || !meta.isUserInteraction) return;
    const targetWeights = normalizeWeights(layout, activeIds);
    setWeights(targetWeights);
    void run(() => applyWeights(snapshot, targetWeights));
  }, [snapshot, busy, activeIds, run, applyWeights]);

  if (!snapshot || !workspacePool || !persistentPool) {
    return (
      <main className="connection-screen">
        <div className="connection-mark">L</div>
        <strong>{error ? "Service unavailable" : "Connecting"}</strong>
        <button type="button" onClick={() => void refresh()}>Retry</button>
      </main>
    );
  }

  const normalizedWeights = normalizeWeights(weights, activeIds);
  const previewPlan = planFromWeights(snapshot, activeWorkers, normalizedWeights);
  const previewById = new Map(previewPlan.map((worker) => [worker.id, worker.allocation]));
  const totalCpu = persistentPool.cpu_capacity_threads + workspacePool.cpu_capacity_threads;
  const totalMemory = persistentPool.memory_capacity_mib + workspacePool.memory_capacity_mib;

  return (
    <div className={`app-shell ${busy ? "busy" : ""}`}>
      <header className="topbar">
        <div className="brand"><span>L</span><strong>Liaison</strong></div>
        <div className="mode-switch" aria-label="Operating mode">
          {(Object.keys(modeLabels) as Mode[]).map((mode) => (
            <button
              type="button"
              key={mode}
              className={snapshot.mode === mode ? "selected" : ""}
              disabled={busy}
              onClick={() => setMode(mode)}
            >
              {modeLabels[mode]}
            </button>
          ))}
        </div>
        <div className="capacity-line">
          <span>{totalCpu} CPU</span>
          <span>{formatGiB(totalMemory)}</span>
          <span className={snapshot.tailscale_online ? "online" : "offline"}>
            {snapshot.tailscale_online ? "Online" : "Offline"}
          </span>
        </div>
      </header>

      <main className="dashboard">
        <section className="workspace-shell">
          <header className="workspace-toolbar">
            <div>
              <p>W pool</p>
              <strong>{workspacePool.cpu_capacity_threads} CPU · {formatGiB(workspacePool.memory_capacity_mib)}</strong>
              <span>Drag a divider to change each worker weight.</span>
            </div>
            <div className="toolbar-actions">
              <button
                type="button"
                className="secondary-button"
                disabled={busy || activeIds.length < 2}
                onClick={equalize}
              >
                Equalize
              </button>
              <button
                type="button"
                className="primary-button"
                disabled={!canAdd || busy}
                onClick={addWorker}
              >
                ＋ Worker
              </button>
            </div>
          </header>

          <div className="managed-board">
            <div className="persistent-rail" aria-label="Persistent layer">
              <div className="rail-heading">
                <span>P layer</span>
                <small>{persistentPool.cpu_capacity_threads} CPU · {formatGiB(persistentPool.memory_capacity_mib)}</small>
              </div>
              <div className="persistent-list">
                {persistent.map((slot) => (
                  <article className="persistent-card" key={slot.id}>
                    <div><strong>{slot.id}</strong><span>{slot.status}</span></div>
                    <p>{slot.allocation.cpu_threads} CPU</p>
                    <p>{formatGiB(slot.allocation.memory_mib)}</p>
                  </article>
                ))}
              </div>
            </div>

            <div className="worker-pool">
              {activeWorkers.length === 0 ? (
                <button
                  type="button"
                  className="empty-pool"
                  disabled={!canAdd || busy}
                  onClick={addWorker}
                >
                  <span>＋</span>
                  <strong>Add the first worker</strong>
                  <small>It receives 100% of the W pool and Shared GPU access.</small>
                </button>
              ) : (
                <Group
                  key={activeKey}
                  id={`worker-weight-group-${activeKey}`}
                  orientation="horizontal"
                  className="worker-group"
                  defaultLayout={normalizedWeights}
                  disabled={busy}
                  onLayoutChange={handleLiveLayout}
                  onLayoutChanged={handleCommittedLayout}
                >
                  {activeWorkers.map((worker, index) => {
                    const allocation = previewById.get(worker.id) ?? worker.allocation;
                    const weight = normalizedWeights[worker.id] ?? 0;
                    return (
                      <React.Fragment key={worker.id}>
                        {index > 0 && (
                          <Separator className="split-separator" title="Drag to change worker weight">
                            <span aria-hidden="true"><i /><i /><i /></span>
                          </Separator>
                        )}
                        <Panel
                          id={worker.id}
                          defaultSize={`${weight}%`}
                          minSize={`${MIN_PANEL_PERCENT}%`}
                          className="worker-panel"
                        >
                          <article className="worker-card">
                            <header>
                              <div><strong>{worker.id}</strong><span>{worker.status}</span></div>
                              <button
                                type="button"
                                className="remove-button"
                                aria-label={`Remove ${worker.id}`}
                                disabled={busy}
                                onClick={() => removeWorker(worker.id)}
                              >
                                ×
                              </button>
                            </header>

                            <div className="weight-display">
                              <strong>{weight.toFixed(weight < 10 ? 1 : 0)}%</strong>
                              <span>weight</span>
                            </div>

                            <div className="worker-specs">
                              <div><strong>{allocation.cpu_threads}</strong><span>CPU</span></div>
                              <div>
                                <strong>{formatGiB(allocation.memory_mib).replace(" GB", "")}</strong>
                                <span>GB</span>
                              </div>
                            </div>

                            <footer>
                              <button
                                type="button"
                                className={`gpu-button ${worker.allocation.gpu}`}
                                title="Click to switch Shared, Exclusive, or Off"
                                disabled={snapshot.mode !== "remote" || busy}
                                onClick={() => cycleGpu(worker)}
                              >
                                {gpuLabels[worker.allocation.gpu]}
                              </button>
                            </footer>
                          </article>
                        </Panel>
                      </React.Fragment>
                    );
                  })}
                </Group>
              )}
            </div>
          </div>
        </section>

        {error && <div className="error-toast">{error}</div>}
      </main>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
