import { invoke } from "@tauri-apps/api/core";
import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { Group, Panel, Separator } from "react-resizable-panels";
import "./styles.css";

type Mode = "remote" | "class" | "local_exclusive" | "maintenance";
type SlotKind = "persistent" | "workspace";
type SlotStatus = "stopped" | "starting" | "running" | "throttled" | "draining" | "error";
type GpuAccess = "none" | "shared" | "exclusive";
type AllocationView = "weights" | "manual";
type WeightMap = Record<string, number>;
type AllocationMap = Record<string, Allocation>;

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
  none: "Off",
  shared: "Shared",
  exclusive: "Exclusive"
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
  if (workers.length === 0) return {};
  const cpuTotal = workers.reduce((sum, worker) => sum + worker.allocation.cpu_threads, 0);
  const memoryTotal = workers.reduce((sum, worker) => sum + worker.allocation.memory_mib, 0);
  const raw = Object.fromEntries(workers.map((worker) => {
    const cpuShare = cpuTotal > 0 ? worker.allocation.cpu_threads / cpuTotal : 0;
    const memoryShare = memoryTotal > 0 ? worker.allocation.memory_mib / memoryTotal : 0;
    return [worker.id, ((cpuShare + memoryShare) / 2) * 100];
  }));
  return normalizeWeights(raw, workers.map((worker) => worker.id));
}

function allocationsFromWorkers(workers: SlotSummary[]): AllocationMap {
  return Object.fromEntries(workers.map((worker) => [worker.id, { ...worker.allocation }]));
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
  const [view, setView] = useState<AllocationView>("weights");
  const [weights, setWeights] = useState<WeightMap>({});
  const [manualAllocations, setManualAllocations] = useState<AllocationMap>({});
  const [manualDirty, setManualDirty] = useState(false);
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
      setManualAllocations({});
      setManualDirty(false);
      return;
    }

    setWeights((current) => {
      const currentIds = Object.keys(current).sort().join(":");
      if (currentIds === activeKey) return normalizeWeights(current, activeIds);
      return weightsFromSnapshot(activeWorkers);
    });

    setManualAllocations((current) => {
      const currentIds = Object.keys(current).sort().join(":");
      if (manualDirty && currentIds === activeKey) return current;
      return allocationsFromWorkers(activeWorkers);
    });
  }, [activeKey, activeIds, activeWorkers, manualDirty]);

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
    setManualDirty(false);

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
          allocation: { ...worker.allocation, gpu: defaultGpu }
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
    setManualDirty(false);
    void run(async () => {
      let current = await call<SystemSnapshot>("stop_slot", { slotId });
      if (remainingIds.length > 0 && view === "weights") {
        current = await applyWeights(current, targetWeights);
      }
      return current;
    });
  }, [snapshot, busy, activeIds, weights, view, run, applyWeights]);

  const equalize = useCallback(() => {
    if (!snapshot || busy || activeIds.length === 0) return;
    const targetWeights = equalWeights(activeIds);
    setWeights(targetWeights);
    setManualDirty(false);
    void run(() => applyWeights(snapshot, targetWeights));
  }, [snapshot, busy, activeIds, run, applyWeights]);

  const setAllShared = useCallback(() => {
    if (!snapshot || busy || snapshot.mode !== "remote" || !snapshot.gpu.available) return;
    const plan = activeWorkers.map((worker): PlannedWorker => ({
      id: worker.id,
      allocation: { ...worker.allocation, gpu: "shared" }
    }));
    setManualAllocations((current) => Object.fromEntries(
      activeWorkers.map((worker) => [
        worker.id,
        { ...(current[worker.id] ?? worker.allocation), gpu: "shared" as GpuAccess }
      ])
    ));
    void run(() => executePlan(snapshot, plan));
  }, [snapshot, busy, activeWorkers, run, executePlan]);

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
    setManualDirty(false);
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
    setManualDirty(false);
    void run(() => applyWeights(snapshot, targetWeights));
  }, [snapshot, busy, activeIds, run, applyWeights]);

  const updateManualAllocation = useCallback((slotId: string, patch: Partial<Allocation>) => {
    setManualAllocations((current) => {
      const fallback = activeWorkers.find((worker) => worker.id === slotId)?.allocation;
      if (!fallback) return current;
      return {
        ...current,
        [slotId]: { ...(current[slotId] ?? fallback), ...patch }
      };
    });
    setManualDirty(true);
  }, [activeWorkers]);

  const resetManual = useCallback(() => {
    setManualAllocations(allocationsFromWorkers(activeWorkers));
    setManualDirty(false);
  }, [activeWorkers]);

  const manualTotals = useMemo(() => activeIds.reduce(
    (totals, id) => {
      const allocation = manualAllocations[id];
      return {
        cpu: totals.cpu + (allocation?.cpu_threads ?? 0),
        memory: totals.memory + (allocation?.memory_mib ?? 0)
      };
    },
    { cpu: 0, memory: 0 }
  ), [activeIds, manualAllocations]);

  const manualValidation = useMemo((): string | null => {
    if (!workspacePool) return "Workspace pool is unavailable.";
    for (const id of activeIds) {
      const allocation = manualAllocations[id];
      if (!allocation || allocation.cpu_threads < MIN_WORKER_CPU) {
        return `${id} needs at least ${MIN_WORKER_CPU} CPU.`;
      }
      if (allocation.memory_mib < MIN_WORKER_MEMORY_MIB) {
        return `${id} needs at least ${formatGiB(MIN_WORKER_MEMORY_MIB)} RAM.`;
      }
      if (snapshot?.mode !== "remote" && allocation.gpu !== "none") {
        return "GPU access is available only in Remote mode.";
      }
    }
    if (manualTotals.cpu > workspacePool.cpu_capacity_threads) {
      return `CPU exceeds the W pool by ${manualTotals.cpu - workspacePool.cpu_capacity_threads}.`;
    }
    if (manualTotals.memory > workspacePool.memory_capacity_mib) {
      return `RAM exceeds the W pool by ${formatGiB(manualTotals.memory - workspacePool.memory_capacity_mib)}.`;
    }
    const allocations = activeIds.map((id) => manualAllocations[id]).filter(Boolean);
    const exclusiveCount = allocations.filter((allocation) => allocation.gpu === "exclusive").length;
    const sharedCount = allocations.filter((allocation) => allocation.gpu === "shared").length;
    if (exclusiveCount > 1 || (exclusiveCount === 1 && sharedCount > 0)) {
      return "Exclusive GPU cannot be combined with another GPU assignment.";
    }
    return null;
  }, [workspacePool, activeIds, manualAllocations, snapshot?.mode, manualTotals]);

  const applyManual = useCallback(() => {
    if (!snapshot || busy || manualValidation || activeIds.length === 0) return;
    const plan = activeIds.map((id): PlannedWorker => ({
      id,
      allocation: { ...manualAllocations[id] }
    }));
    void (async () => {
      const next = await run(() => executePlan(snapshot, plan));
      if (!next) return;
      const nextWorkers = next.slots
        .filter((slot) => slot.kind === "workspace" && isActive(slot))
        .sort((left, right) => left.id.localeCompare(right.id));
      setWeights(weightsFromSnapshot(nextWorkers));
      setManualAllocations(allocationsFromWorkers(nextWorkers));
      setManualDirty(false);
    })();
  }, [snapshot, busy, manualValidation, activeIds, manualAllocations, run, executePlan]);

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
  const unusedCpu = Math.max(0, workspacePool.cpu_capacity_threads - manualTotals.cpu);
  const unusedMemory = Math.max(0, workspacePool.memory_capacity_mib - manualTotals.memory);

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
          <span className={snapshot.runtime === "wsl-docker" ? "online" : "offline"}>
            {snapshot.runtime === "wsl-docker" ? "Production" : "Mock"}
          </span>
        </div>
      </header>

      <main className="dashboard">
        <section className="workspace-shell">
          <header className="workspace-toolbar">
            <div className="pool-summary">
              <p>W pool</p>
              <strong>{workspacePool.cpu_capacity_threads} CPU · {formatGiB(workspacePool.memory_capacity_mib)}</strong>
              <span>{view === "weights" ? "Drag dividers to distribute one shared pool." : "Enter exact limits for each worker."}</span>
            </div>

            <div className="toolbar-actions">
              <div className="view-switch" aria-label="Allocation editor">
                <button
                  type="button"
                  className={view === "weights" ? "selected" : ""}
                  onClick={() => setView("weights")}
                >
                  Weight
                </button>
                <button
                  type="button"
                  className={view === "manual" ? "selected" : ""}
                  onClick={() => setView("manual")}
                >
                  Manual
                </button>
              </div>

              {view === "weights" ? (
                <button
                  type="button"
                  className="secondary-button"
                  disabled={busy || activeIds.length < 2}
                  onClick={equalize}
                >
                  Equalize
                </button>
              ) : (
                <>
                  <button
                    type="button"
                    className="secondary-button"
                    disabled={busy || !manualDirty}
                    onClick={resetManual}
                  >
                    Reset
                  </button>
                  <button
                    type="button"
                    className="primary-button"
                    disabled={busy || !manualDirty || Boolean(manualValidation)}
                    onClick={applyManual}
                  >
                    Apply
                  </button>
                </>
              )}

              <button
                type="button"
                className="secondary-button gpu-default-button"
                disabled={busy || activeIds.length === 0 || snapshot.mode !== "remote" || !snapshot.gpu.available}
                onClick={setAllShared}
              >
                GPU Shared
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
            <aside className="persistent-rail" aria-label="Persistent layer">
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
            </aside>

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
                  <small>It receives the full W pool and Shared GPU access.</small>
                </button>
              ) : view === "weights" ? (
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
                                GPU {gpuLabels[worker.allocation.gpu]}
                              </button>
                            </footer>
                          </article>
                        </Panel>
                      </React.Fragment>
                    );
                  })}
                </Group>
              ) : (
                <div className="manual-editor">
                  <div className={`manual-usage ${manualValidation ? "invalid" : ""}`}>
                    <div><span>CPU</span><strong>{manualTotals.cpu} / {workspacePool.cpu_capacity_threads}</strong><small>{unusedCpu} free</small></div>
                    <div><span>RAM</span><strong>{formatGiB(manualTotals.memory)} / {formatGiB(workspacePool.memory_capacity_mib)}</strong><small>{formatGiB(unusedMemory)} free</small></div>
                    <p>{manualValidation ?? "Exact limits are applied together when you press Apply."}</p>
                  </div>

                  <div className="manual-list">
                    {activeWorkers.map((worker) => {
                      const allocation = manualAllocations[worker.id] ?? worker.allocation;
                      return (
                        <article className="manual-row" key={worker.id}>
                          <div className="manual-worker-id">
                            <strong>{worker.id}</strong>
                            <span>{worker.status}</span>
                          </div>

                          <label>
                            <span>CPU threads</span>
                            <input
                              type="number"
                              min={MIN_WORKER_CPU}
                              max={workspacePool.cpu_capacity_threads}
                              step={1}
                              value={allocation.cpu_threads}
                              disabled={busy}
                              onChange={(event: React.ChangeEvent<HTMLInputElement>) => updateManualAllocation(worker.id, {
                                cpu_threads: Math.max(0, Math.round(Number(event.target.value)))
                              })}
                            />
                          </label>

                          <label>
                            <span>RAM (GB)</span>
                            <input
                              type="number"
                              min={0.5}
                              max={workspacePool.memory_capacity_mib / 1024}
                              step={0.5}
                              value={allocation.memory_mib / 1024}
                              disabled={busy}
                              onChange={(event: React.ChangeEvent<HTMLInputElement>) => updateManualAllocation(worker.id, {
                                memory_mib: Math.max(0, Math.round(Number(event.target.value) * 2) * 512)
                              })}
                            />
                          </label>

                          <label>
                            <span>GPU</span>
                            <select
                              value={allocation.gpu}
                              disabled={busy || snapshot.mode !== "remote"}
                              onChange={(event: React.ChangeEvent<HTMLSelectElement>) => updateManualAllocation(worker.id, {
                                gpu: event.target.value as GpuAccess
                              })}
                            >
                              <option value="shared">Shared</option>
                              <option value="exclusive">Exclusive</option>
                              <option value="none">Off</option>
                            </select>
                          </label>

                          <button
                            type="button"
                            className="remove-button"
                            aria-label={`Remove ${worker.id}`}
                            disabled={busy}
                            onClick={() => removeWorker(worker.id)}
                          >
                            ×
                          </button>
                        </article>
                      );
                    })}
                  </div>
                </div>
              )}
            </div>
          </div>
        </section>

        {busy && <div className="apply-indicator">Applying configuration…</div>}
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
