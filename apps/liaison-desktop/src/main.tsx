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

interface TileLayout {
  x: number;
  y: number;
  w: number;
  h: number;
}

interface PlannedWorker {
  id: string;
  allocation: Allocation;
}

const GRID_COLUMNS = 24;
const GRID_ROWS = 16;
const WORKER_MAX_WIDTH = 18;
const WORKER_MAX_HEIGHT = 13;
const MIN_WORKER_CPU = 1;
const MIN_WORKER_MEMORY_MIB = 512;

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
const clamp = (value: number, minimum: number, maximum: number): number =>
  Math.min(maximum, Math.max(minimum, value));
const formatGiB = (mib: number): string => {
  const value = mib / 1024;
  return `${Number.isInteger(value) ? value.toFixed(0) : value.toFixed(1)} GB`;
};

async function call<T>(command: string, args: Record<string, unknown> = {}): Promise<T> {
  return invoke<T>(command, args);
}

function splitCapacity(total: number, count: number, minimum: number): number[] {
  if (count <= 0) return [];
  const safeTotal = Math.max(total, minimum * count);
  const base = Math.floor(safeTotal / count);
  const remainder = safeTotal % count;
  return Array.from({ length: count }, (_, index) => base + (index < remainder ? 1 : 0));
}

function collides(candidate: TileLayout, other: TileLayout): boolean {
  return !(
    candidate.x + candidate.w <= other.x
    || other.x + other.w <= candidate.x
    || candidate.y + candidate.h <= other.y
    || other.y + other.h <= candidate.y
  );
}

function fitsBoard(candidate: TileLayout): boolean {
  return candidate.x >= 0
    && candidate.y >= 0
    && candidate.x + candidate.w <= GRID_COLUMNS
    && candidate.y + candidate.h <= GRID_ROWS;
}

function findVacancy(occupied: TileLayout[], width: number, height: number): TileLayout {
  for (let y = 0; y <= GRID_ROWS - height; y += 1) {
    for (let x = 0; x <= GRID_COLUMNS - width; x += 1) {
      const candidate = { x, y, w: width, h: height };
      if (!occupied.some((other) => collides(candidate, other))) return candidate;
    }
  }
  return {
    x: 0,
    y: 0,
    w: Math.min(width, GRID_COLUMNS),
    h: Math.min(height, GRID_ROWS)
  };
}

function desiredTileSize(slot: SlotSummary, workspacePool: PoolSummary): Pick<TileLayout, "w" | "h"> {
  if (slot.kind === "persistent") return { w: 4, h: 3 };
  const cpuRatio = workspacePool.cpu_capacity_threads > 0
    ? slot.allocation.cpu_threads / workspacePool.cpu_capacity_threads
    : 0;
  const memoryRatio = workspacePool.memory_capacity_mib > 0
    ? slot.allocation.memory_mib / workspacePool.memory_capacity_mib
    : 0;
  return {
    w: clamp(Math.round(cpuRatio * WORKER_MAX_WIDTH), 4, WORKER_MAX_WIDTH),
    h: clamp(Math.round(memoryRatio * WORKER_MAX_HEIGHT), 3, WORKER_MAX_HEIGHT)
  };
}

function nextGpuAccess(current: GpuAccess): GpuAccess {
  if (current === "none") return "shared";
  if (current === "shared") return "exclusive";
  return "none";
}

function App(): React.JSX.Element {
  const [snapshot, setSnapshot] = useState<SystemSnapshot | null>(null);
  const [layouts, setLayouts] = useState<Record<string, TileLayout>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const boardRef = useRef<HTMLDivElement | null>(null);
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

  const slots = snapshot?.slots ?? [];
  const persistent = useMemo(
    () => slots.filter((slot) => slot.kind === "persistent" && isActive(slot)),
    [slots]
  );
  const workers = useMemo(
    () => slots.filter((slot) => slot.kind === "workspace"),
    [slots]
  );
  const activeWorkers = useMemo(() => workers.filter(isActive), [workers]);
  const workspacePool = snapshot?.pools.find((pool) => pool.id === "workspace");
  const persistentPool = snapshot?.pools.find((pool) => pool.id === "persistent");

  useEffect(() => {
    if (!snapshot || !workspacePool) return;
    const activeSlots = [...persistent, ...activeWorkers];
    setLayouts((current) => {
      const next: Record<string, TileLayout> = {};
      const occupied: TileLayout[] = [];
      for (const slot of activeSlots) {
        const size = desiredTileSize(slot, workspacePool);
        const previous = current[slot.id];
        const candidate = previous
          ? { x: previous.x, y: previous.y, ...size }
          : findVacancy(occupied, size.w, size.h);
        const placed = fitsBoard(candidate) && !occupied.some((other) => collides(candidate, other))
          ? candidate
          : findVacancy(occupied, size.w, size.h);
        next[slot.id] = placed;
        occupied.push(placed);
      }
      return next;
    });
  }, [snapshot, workspacePool, persistent, activeWorkers]);

  const run = useCallback(async (action: () => Promise<SystemSnapshot>): Promise<SystemSnapshot | null> => {
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
    const activeIds = new Set(plan.map((worker) => worker.id));
    const currentWorkers = current.slots.filter(
      (slot) => slot.kind === "workspace" && isActive(slot) && activeIds.has(slot.id)
    );

    for (const slot of currentWorkers) {
      current = await assign({
        id: slot.id,
        allocation: {
          cpu_threads: MIN_WORKER_CPU,
          memory_mib: MIN_WORKER_MEMORY_MIB,
          gpu: slot.allocation.gpu
        }
      });
    }

    for (const worker of plan) current = await assign(worker);
    return current;
  }, [assign]);

  const balancedPlan = useCallback((base: SystemSnapshot, ids: string[]): PlannedWorker[] => {
    const pool = base.pools.find((candidate) => candidate.id === "workspace");
    if (!pool || ids.length === 0) return [];
    const cpuValues = splitCapacity(pool.cpu_capacity_threads, ids.length, MIN_WORKER_CPU);
    const memoryValues = splitCapacity(
      pool.memory_capacity_mib,
      ids.length,
      MIN_WORKER_MEMORY_MIB
    );
    return ids.map((id, index) => {
      const slot = base.slots.find((candidate) => candidate.id === id);
      return {
        id,
        allocation: {
          cpu_threads: cpuValues[index],
          memory_mib: memoryValues[index],
          gpu: slot?.allocation.gpu ?? "none"
        }
      };
    });
  }, []);

  const addWorker = useCallback(() => {
    if (!snapshot || !workspacePool || busy) return;
    const next = workers.find((worker) => !isActive(worker));
    if (!next) return;
    void run(async () => {
      let current = await assign({
        id: next.id,
        allocation: {
          cpu_threads: MIN_WORKER_CPU,
          memory_mib: MIN_WORKER_MEMORY_MIB,
          gpu: "none"
        }
      });
      const ids = current.slots
        .filter((slot) => slot.kind === "workspace" && isActive(slot))
        .map((slot) => slot.id)
        .sort();
      current = await executePlan(current, balancedPlan(current, ids));
      return current;
    });
  }, [snapshot, workspacePool, busy, workers, run, assign, executePlan, balancedPlan]);

  const removeWorker = useCallback((slotId: string) => {
    if (!snapshot || busy) return;
    void run(async () => {
      let current = await call<SystemSnapshot>("stop_slot", { slotId });
      const ids = current.slots
        .filter((slot) => slot.kind === "workspace" && isActive(slot))
        .map((slot) => slot.id)
        .sort();
      if (ids.length > 0) current = await executePlan(current, balancedPlan(current, ids));
      return current;
    });
  }, [snapshot, busy, run, executePlan, balancedPlan]);

  const resizeWorker = useCallback((slotId: string, layout: TileLayout) => {
    if (!snapshot || !workspacePool || busy) return;
    const ids = activeWorkers.map((worker) => worker.id).sort();
    const count = ids.length;
    if (count === 0) return;
    const maximumCpu = workspacePool.cpu_capacity_threads - MIN_WORKER_CPU * (count - 1);
    const maximumMemory = workspacePool.memory_capacity_mib - MIN_WORKER_MEMORY_MIB * (count - 1);
    const requestedCpu = clamp(
      Math.round((layout.w / WORKER_MAX_WIDTH) * workspacePool.cpu_capacity_threads),
      MIN_WORKER_CPU,
      maximumCpu
    );
    const requestedMemory = clamp(
      Math.round((layout.h / WORKER_MAX_HEIGHT) * workspacePool.memory_capacity_mib / 512) * 512,
      MIN_WORKER_MEMORY_MIB,
      maximumMemory
    );

    void run(async () => {
      const otherIds = ids.filter((id) => id !== slotId);
      const otherCpu = splitCapacity(
        workspacePool.cpu_capacity_threads - requestedCpu,
        otherIds.length,
        MIN_WORKER_CPU
      );
      const otherMemory = splitCapacity(
        workspacePool.memory_capacity_mib - requestedMemory,
        otherIds.length,
        MIN_WORKER_MEMORY_MIB
      );
      const plan: PlannedWorker[] = ids.map((id) => {
        const slot = snapshot.slots.find((candidate) => candidate.id === id);
        if (id === slotId) {
          return {
            id,
            allocation: {
              cpu_threads: requestedCpu,
              memory_mib: requestedMemory,
              gpu: slot?.allocation.gpu ?? "none"
            }
          };
        }
        const index = otherIds.indexOf(id);
        return {
          id,
          allocation: {
            cpu_threads: otherCpu[index],
            memory_mib: otherMemory[index],
            gpu: slot?.allocation.gpu ?? "none"
          }
        };
      });
      return executePlan(snapshot, plan);
    });
  }, [snapshot, workspacePool, busy, activeWorkers, run, executePlan]);

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

  const startGesture = useCallback((
    event: React.PointerEvent<HTMLElement>,
    slot: SlotSummary,
    gesture: "move" | "resize"
  ) => {
    if (busy || slot.kind === "persistent") return;
    const board = boardRef.current;
    const original = layouts[slot.id];
    if (!board || !original) return;
    event.preventDefault();
    event.stopPropagation();

    const bounds = board.getBoundingClientRect();
    const startX = event.clientX;
    const startY = event.clientY;
    let latest = original;

    const move = (pointer: PointerEvent): void => {
      const deltaX = Math.round(((pointer.clientX - startX) / bounds.width) * GRID_COLUMNS);
      const deltaY = Math.round(((pointer.clientY - startY) / bounds.height) * GRID_ROWS);
      const candidate = gesture === "move"
        ? {
            ...original,
            x: clamp(original.x + deltaX, 0, GRID_COLUMNS - original.w),
            y: clamp(original.y + deltaY, 0, GRID_ROWS - original.h)
          }
        : {
            ...original,
            w: clamp(original.w + deltaX, 4, WORKER_MAX_WIDTH),
            h: clamp(original.h + deltaY, 3, WORKER_MAX_HEIGHT)
          };

      setLayouts((current) => {
        const occupied = Object.entries(current)
          .filter(([id]) => id !== slot.id)
          .map(([, layout]) => layout);
        if (!fitsBoard(candidate) || occupied.some((other) => collides(candidate, other))) {
          return current;
        }
        latest = candidate;
        return { ...current, [slot.id]: candidate };
      });
    };

    const end = (): void => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", end);
      if (gesture === "resize" && latest !== original) resizeWorker(slot.id, latest);
    };

    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", end, { once: true });
  }, [busy, layouts, resizeWorker]);

  if (!snapshot || !workspacePool || !persistentPool) {
    return (
      <main className="connection-screen">
        <div className="connection-mark">L</div>
        <strong>{error ? "Service unavailable" : "Connecting"}</strong>
        <button type="button" onClick={() => void refresh()}>Retry</button>
      </main>
    );
  }

  const activeSlots = [...persistent, ...activeWorkers];
  const totalCpu = persistentPool.cpu_capacity_threads + workspacePool.cpu_capacity_threads;
  const totalMemory = persistentPool.memory_capacity_mib + workspacePool.memory_capacity_mib;
  const canAdd = workers.some((worker) => !isActive(worker))
    && snapshot.mode !== "local_exclusive"
    && snapshot.mode !== "maintenance";

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
          <span className={snapshot.gpu.available ? "online" : "offline"}>GPU</span>
        </div>
      </header>

      <main className="dashboard">
        <div className="board-toolbar">
          <div>
            <strong>{activeWorkers.length} worker{activeWorkers.length === 1 ? "" : "s"}</strong>
            <span>Drag to arrange. Resize a corner to redistribute the W pool.</span>
          </div>
          <button type="button" className="add-worker" disabled={!canAdd || busy} onClick={addWorker}>
            <span>＋</span> Worker
          </button>
        </div>

        {error && <div className="error-toast">{error}</div>}

        <section
          className="bento-board"
          ref={boardRef}
          onDoubleClick={() => { if (canAdd) addWorker(); }}
          aria-label="Managed capacity bento board"
        >
          {activeSlots.map((slot) => {
            const layout = layouts[slot.id];
            if (!layout) return null;
            const compact = layout.w <= 5 || layout.h <= 3;
            const isPersistent = slot.kind === "persistent";
            return (
              <article
                className={`bento-tile ${slot.kind} ${compact ? "compact" : ""}`}
                key={slot.id}
                style={{
                  left: `${(layout.x / GRID_COLUMNS) * 100}%`,
                  top: `${(layout.y / GRID_ROWS) * 100}%`,
                  width: `${(layout.w / GRID_COLUMNS) * 100}%`,
                  height: `${(layout.h / GRID_ROWS) * 100}%`
                }}
                onDoubleClick={(event) => event.stopPropagation()}
                onPointerDown={(event) => startGesture(event, slot, "move")}
              >
                <header>
                  <div>
                    <strong>{slot.id}</strong>
                    <span>{isPersistent ? "Persistent" : slot.status}</span>
                  </div>
                  {!isPersistent && (
                    <button
                      type="button"
                      className="tile-remove"
                      aria-label={`Remove ${slot.id}`}
                      onPointerDown={(event) => event.stopPropagation()}
                      onClick={(event) => {
                        event.stopPropagation();
                        removeWorker(slot.id);
                      }}
                    >
                      ×
                    </button>
                  )}
                </header>

                <div className="tile-specs">
                  <div><b>{slot.allocation.cpu_threads}</b><span>CPU</span></div>
                  <div><b>{formatGiB(slot.allocation.memory_mib).replace(" GB", "")}</b><span>GB</span></div>
                </div>

                <footer>
                  {isPersistent ? (
                    <span className="locked">Locked</span>
                  ) : (
                    <button
                      type="button"
                      className={`gpu-chip ${slot.allocation.gpu}`}
                      disabled={snapshot.mode !== "remote" || busy}
                      onPointerDown={(event) => event.stopPropagation()}
                      onClick={(event) => {
                        event.stopPropagation();
                        cycleGpu(slot);
                      }}
                    >
                      {gpuLabels[slot.allocation.gpu]}
                    </button>
                  )}
                </footer>

                {!isPersistent && (
                  <button
                    type="button"
                    className="resize-handle"
                    aria-label={`Resize ${slot.id}`}
                    onPointerDown={(event) => startGesture(event, slot, "resize")}
                  />
                )}
              </article>
            );
          })}

          {activeWorkers.length === 0 && (
            <button type="button" className="empty-board" disabled={!canAdd} onClick={addWorker}>
              <span>＋</span>
              <strong>Create a worker block</strong>
              <small>It will automatically use the available W capacity.</small>
            </button>
          )}
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
