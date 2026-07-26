import { invoke } from "@tauri-apps/api/core";
import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import "./styles.css";

type Mode = "remote" | "class" | "local_exclusive" | "maintenance";
type RuntimeKind = "mock" | "wsl-docker";
type SlotKind = "persistent" | "workspace";
type SlotStatus = "stopped" | "starting" | "running" | "throttled" | "draining" | "error";
type GpuAccess = "none" | "shared" | "exclusive";
type SettingsSection = "general" | "workers" | "persistent" | "runtime";
type AllocationPreset = "balanced" | "performance" | "headroom";

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
  runtime: RuntimeKind;
  service_online: boolean;
  tailscale_online: boolean;
  auto_tuned: boolean;
  host_cpu_threads: number;
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

interface SlotDraft extends Allocation {
  enabled: boolean;
}

type DraftMap = Record<string, SlotDraft>;

interface PlannedWorker {
  id: string;
  allocation: Allocation;
}

const MIN_CPU = 1;
const MIN_MEMORY_MIB = 512;

const modeLabels: Record<Mode, string> = {
  remote: "Remote",
  class: "Class",
  local_exclusive: "Local exclusive",
  maintenance: "Maintenance"
};

const sectionLabels: Record<SettingsSection, { title: string; description: string }> = {
  general: { title: "一般設定", description: "運用モードと自動配分を設定します。" },
  workers: { title: "Workers", description: "W1〜W5のCPU・RAM・GPUを個別に設定します。" },
  persistent: { title: "Persistent", description: "P1・P2の常駐リソースを設定します。" },
  runtime: { title: "Runtime", description: "検出されたマシン情報と実行環境を確認します。" }
};

const isActive = (slot: SlotSummary): boolean => slot.status !== "stopped";

const formatGiB = (mib: number): string => {
  const value = mib / 1024;
  return `${Number.isInteger(value) ? value.toFixed(0) : value.toFixed(1)} GB`;
};

const formatPercent = (value: number): string => `${Math.round(value)}%`;

async function call<T>(command: string, args: Record<string, unknown> = {}): Promise<T> {
  return invoke<T>(command, args);
}

function draftFromSlots(slots: SlotSummary[]): DraftMap {
  return Object.fromEntries(slots.map((slot) => [
    slot.id,
    {
      enabled: isActive(slot),
      cpu_threads: isActive(slot) ? slot.allocation.cpu_threads : MIN_CPU,
      memory_mib: isActive(slot) ? slot.allocation.memory_mib : MIN_MEMORY_MIB,
      gpu: isActive(slot) ? slot.allocation.gpu : "none"
    }
  ]));
}

function normalizeWeights(ids: string[], values: number[]): Record<string, number> {
  const positive = values.map((value) => Math.max(0, value));
  const total = positive.reduce((sum, value) => sum + value, 0);
  if (ids.length === 0) return {};
  if (total <= 0) return Object.fromEntries(ids.map((id) => [id, 1 / ids.length]));
  return Object.fromEntries(ids.map((id, index) => [id, positive[index] / total]));
}

function allocateWeighted(
  capacity: number,
  ids: string[],
  weights: Record<string, number>,
  minimum: number,
  quantum = 1,
  usageRatio = 1
): Record<string, number> {
  if (ids.length === 0) return {};
  const capacityUnits = Math.floor(capacity / quantum);
  const minimumUnits = Math.ceil(minimum / quantum);
  const targetUnits = Math.max(
    minimumUnits * ids.length,
    Math.floor(capacityUnits * usageRatio)
  );
  const distributable = Math.max(0, targetUnits - minimumUnits * ids.length);
  const rawExtras = ids.map((id) => (weights[id] ?? 0) * distributable);
  const extras = rawExtras.map(Math.floor);
  let remainder = distributable - extras.reduce((sum, value) => sum + value, 0);
  const order = rawExtras
    .map((value, index) => ({ index, fraction: value - Math.floor(value) }))
    .sort((left, right) => right.fraction - left.fraction);

  for (const entry of order) {
    if (remainder <= 0) break;
    extras[entry.index] += 1;
    remainder -= 1;
  }

  return Object.fromEntries(
    ids.map((id, index) => [id, (minimumUnits + extras[index]) * quantum])
  );
}

function presetPlan(
  pool: PoolSummary,
  ids: string[],
  preset: AllocationPreset,
  gpu: GpuAccess
): PlannedWorker[] {
  if (ids.length === 0) return [];
  const weights = preset === "performance" && ids.length > 1
    ? normalizeWeights(ids, ids.map((_, index) => index === 0 ? 50 : 50 / (ids.length - 1)))
    : normalizeWeights(ids, ids.map(() => 1));
  const usageRatio = preset === "headroom" ? 0.75 : 1;
  const cpu = allocateWeighted(pool.cpu_capacity_threads, ids, weights, MIN_CPU, 1, usageRatio);
  const memory = allocateWeighted(
    pool.memory_capacity_mib,
    ids,
    weights,
    MIN_MEMORY_MIB,
    512,
    usageRatio
  );

  return ids.map((id): PlannedWorker => ({
    id,
    allocation: {
      cpu_threads: cpu[id],
      memory_mib: memory[id],
      gpu
    }
  }));
}

function validationForDrafts(
  drafts: DraftMap,
  ids: string[],
  pool: PoolSummary,
  mode: Mode,
  allowGpu: boolean
): string | null {
  const enabled = ids.filter((id) => drafts[id]?.enabled);
  let cpu = 0;
  let memory = 0;
  let exclusive = 0;
  let shared = 0;

  for (const id of enabled) {
    const draft = drafts[id];
    if (!draft || draft.cpu_threads < MIN_CPU) return `${id}: CPUは1以上にしてください。`;
    if (draft.memory_mib < MIN_MEMORY_MIB) return `${id}: RAMは0.5 GB以上にしてください。`;
    if ((!allowGpu || mode !== "remote") && draft.gpu !== "none") {
      return "GPUはRemoteモードでのみ利用できます。";
    }
    cpu += draft.cpu_threads;
    memory += draft.memory_mib;
    if (draft.gpu === "exclusive") exclusive += 1;
    if (draft.gpu === "shared") shared += 1;
  }

  if (cpu > pool.cpu_capacity_threads) {
    return `CPUがプール上限を${cpu - pool.cpu_capacity_threads}スレッド超えています。`;
  }
  if (memory > pool.memory_capacity_mib) {
    return `RAMがプール上限を${formatGiB(memory - pool.memory_capacity_mib)}超えています。`;
  }
  if (exclusive > 1 || (exclusive === 1 && shared > 0)) {
    return "Exclusive GPUは他のGPU割り当てと併用できません。";
  }
  return null;
}

function totalsForDrafts(drafts: DraftMap, ids: string[]): { cpu: number; memory: number; enabled: number } {
  return ids.reduce((totals, id) => {
    const draft = drafts[id];
    if (!draft?.enabled) return totals;
    return {
      cpu: totals.cpu + draft.cpu_threads,
      memory: totals.memory + draft.memory_mib,
      enabled: totals.enabled + 1
    };
  }, { cpu: 0, memory: 0, enabled: 0 });
}

function App(): React.JSX.Element {
  const [snapshot, setSnapshot] = useState<SystemSnapshot | null>(null);
  const [section, setSection] = useState<SettingsSection>("general");
  const [workerDrafts, setWorkerDrafts] = useState<DraftMap>({});
  const [persistentDrafts, setPersistentDrafts] = useState<DraftMap>({});
  const [workersDirty, setWorkersDirty] = useState(false);
  const [persistentDirty, setPersistentDirty] = useState(false);
  const [preset, setPreset] = useState<AllocationPreset>("balanced");
  const [targetWorkerCount, setTargetWorkerCount] = useState(1);
  const [sharedGpuDefault, setSharedGpuDefault] = useState(true);
  const [generalDirty, setGeneralDirty] = useState(false);
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
  const workers = useMemo(
    () => slots.filter((slot) => slot.kind === "workspace").sort((a, b) => a.id.localeCompare(b.id)),
    [slots]
  );
  const persistent = useMemo(
    () => slots.filter((slot) => slot.kind === "persistent").sort((a, b) => a.id.localeCompare(b.id)),
    [slots]
  );
  const workerIds = useMemo(() => workers.map((slot) => slot.id), [workers]);
  const persistentIds = useMemo(() => persistent.map((slot) => slot.id), [persistent]);
  const activeWorkerCount = workers.filter(isActive).length;
  const workspacePool = snapshot?.pools.find((pool) => pool.id === "workspace");
  const persistentPool = snapshot?.pools.find((pool) => pool.id === "persistent");
  const maxAutoWorkers = workspacePool
    ? Math.max(0, Math.min(
        workerIds.length,
        workspacePool.cpu_capacity_threads,
        Math.floor(workspacePool.memory_capacity_mib / MIN_MEMORY_MIB)
      ))
    : 0;

  useEffect(() => {
    if (!snapshot) return;
    if (!workersDirty) setWorkerDrafts(draftFromSlots(workers));
    if (!persistentDirty) setPersistentDrafts(draftFromSlots(persistent));
    if (!generalDirty) {
      setTargetWorkerCount(activeWorkerCount);
      setSharedGpuDefault(
        snapshot.mode === "remote"
        && snapshot.gpu.available
        && workers.filter(isActive).every((slot) => slot.allocation.gpu === "shared")
      );
    }
  }, [snapshot, workers, persistent, activeWorkerCount, workersDirty, persistentDirty, generalDirty]);

  const assignWorker = useCallback((worker: PlannedWorker): Promise<SystemSnapshot> => (
    call<SystemSnapshot>("assign_worker", {
      slotId: worker.id,
      cpuThreads: worker.allocation.cpu_threads,
      memoryMib: worker.allocation.memory_mib,
      gpu: worker.allocation.gpu
    })
  ), []);

  const executeWorkspacePlan = useCallback(async (
    base: SystemSnapshot,
    plan: PlannedWorker[]
  ): Promise<SystemSnapshot> => {
    let current = base;
    const desiredIds = new Set(plan.map((worker) => worker.id));

    for (const slot of current.slots.filter((candidate) => (
      candidate.kind === "workspace" && isActive(candidate) && !desiredIds.has(candidate.id)
    ))) {
      current = await call<SystemSnapshot>("stop_slot", { slotId: slot.id });
    }

    const targets = new Map(plan.map((worker) => [worker.id, worker]));
    const activeDesired = current.slots
      .filter((slot) => slot.kind === "workspace" && isActive(slot) && desiredIds.has(slot.id))
      .sort((left, right) => {
        const leftExclusive = targets.get(left.id)?.allocation.gpu === "exclusive" ? -1 : 0;
        const rightExclusive = targets.get(right.id)?.allocation.gpu === "exclusive" ? -1 : 0;
        return leftExclusive - rightExclusive;
      });

    for (const slot of activeDesired) {
      const target = targets.get(slot.id);
      if (!target) continue;
      current = await assignWorker({
        id: slot.id,
        allocation: {
          cpu_threads: MIN_CPU,
          memory_mib: MIN_MEMORY_MIB,
          gpu: target.allocation.gpu
        }
      });
    }

    for (const worker of plan) {
      const slot = current.slots.find((candidate) => candidate.id === worker.id);
      if (!slot || !isActive(slot)) {
        current = await assignWorker({
          id: worker.id,
          allocation: {
            cpu_threads: MIN_CPU,
            memory_mib: MIN_MEMORY_MIB,
            gpu: worker.allocation.gpu
          }
        });
      }
    }

    for (const worker of plan) current = await assignWorker(worker);
    return current;
  }, [assignWorker]);

  const executePersistentPlan = useCallback(async (
    base: SystemSnapshot,
    drafts: DraftMap
  ): Promise<SystemSnapshot> => {
    let current = base;
    const enabledIds = persistentIds.filter((id) => drafts[id]?.enabled);

    for (const slot of current.slots.filter((candidate) => (
      candidate.kind === "persistent" && isActive(candidate) && !enabledIds.includes(candidate.id)
    ))) {
      current = await call<SystemSnapshot>("stop_slot", { slotId: slot.id });
    }

    for (const id of enabledIds) {
      const slot = current.slots.find((candidate) => candidate.id === id);
      if (slot && isActive(slot)) {
        current = await call<SystemSnapshot>("resize_slot", {
          slotId: id,
          cpuThreads: MIN_CPU,
          memoryMib: MIN_MEMORY_MIB
        });
      }
    }

    for (const id of enabledIds) {
      const slot = current.slots.find((candidate) => candidate.id === id);
      if (!slot || !isActive(slot)) {
        current = await call<SystemSnapshot>("start_slot", { slotId: id });
      }
    }

    for (const id of enabledIds) {
      const draft = drafts[id];
      current = await call<SystemSnapshot>("resize_slot", {
        slotId: id,
        cpuThreads: draft.cpu_threads,
        memoryMib: draft.memory_mib
      });
    }

    return current;
  }, [persistentIds]);

  const workerTotals = useMemo(
    () => totalsForDrafts(workerDrafts, workerIds),
    [workerDrafts, workerIds]
  );
  const persistentTotals = useMemo(
    () => totalsForDrafts(persistentDrafts, persistentIds),
    [persistentDrafts, persistentIds]
  );
  const workerValidation = useMemo(() => (
    snapshot && workspacePool
      ? validationForDrafts(workerDrafts, workerIds, workspacePool, snapshot.mode, snapshot.gpu.available)
      : null
  ), [snapshot, workspacePool, workerDrafts, workerIds]);
  const persistentValidation = useMemo(() => (
    snapshot && persistentPool
      ? validationForDrafts(persistentDrafts, persistentIds, persistentPool, snapshot.mode, false)
      : null
  ), [snapshot, persistentPool, persistentDrafts, persistentIds]);

  const setMode = useCallback((mode: Mode) => {
    if (!snapshot || busy || snapshot.mode === mode) return;
    setGeneralDirty(false);
    setWorkersDirty(false);
    setPersistentDirty(false);
    void run(() => call<SystemSnapshot>("set_mode", { mode }));
  }, [snapshot, busy, run]);

  const updateWorkerDraft = useCallback((id: string, patch: Partial<SlotDraft>) => {
    setWorkerDrafts((current) => ({
      ...current,
      [id]: { ...current[id], ...patch }
    }));
    setWorkersDirty(true);
  }, []);

  const updatePersistentDraft = useCallback((id: string, patch: Partial<SlotDraft>) => {
    setPersistentDrafts((current) => ({
      ...current,
      [id]: { ...current[id], ...patch, gpu: "none" }
    }));
    setPersistentDirty(true);
  }, []);

  const balanceWorkerDrafts = useCallback(() => {
    if (!snapshot || !workspacePool || workerIds.length === 0) return;
    const enabledIds = workerIds.filter((id) => workerDrafts[id]?.enabled);
    const ids = enabledIds.length > 0 ? enabledIds : [workerIds[0]];
    const gpu: GpuAccess = snapshot.mode === "remote" && snapshot.gpu.available ? "shared" : "none";
    const plan = presetPlan(workspacePool, ids, "balanced", gpu);
    const byId = new Map(plan.map((worker) => [worker.id, worker.allocation]));
    setWorkerDrafts((current) => Object.fromEntries(workerIds.map((id) => {
      const allocation = byId.get(id);
      return [id, allocation
        ? { enabled: true, ...allocation }
        : { ...current[id], enabled: false }];
    })));
    setWorkersDirty(true);
  }, [snapshot, workspacePool, workerIds, workerDrafts]);

  const resetWorkers = useCallback(() => {
    setWorkerDrafts(draftFromSlots(workers));
    setWorkersDirty(false);
  }, [workers]);

  const resetPersistent = useCallback(() => {
    setPersistentDrafts(draftFromSlots(persistent));
    setPersistentDirty(false);
  }, [persistent]);

  const applyWorkers = useCallback(() => {
    if (!snapshot || busy || workerValidation) return;
    const plan = workerIds
      .filter((id) => workerDrafts[id]?.enabled)
      .map((id): PlannedWorker => ({
        id,
        allocation: {
          cpu_threads: workerDrafts[id].cpu_threads,
          memory_mib: workerDrafts[id].memory_mib,
          gpu: workerDrafts[id].gpu
        }
      }));
    void (async () => {
      const next = await run(() => executeWorkspacePlan(snapshot, plan));
      if (!next) return;
      setWorkerDrafts(draftFromSlots(next.slots.filter((slot) => slot.kind === "workspace")));
      setTargetWorkerCount(plan.length);
      setWorkersDirty(false);
      setGeneralDirty(false);
    })();
  }, [snapshot, busy, workerValidation, workerIds, workerDrafts, run, executeWorkspacePlan]);

  const applyPersistent = useCallback(() => {
    if (!snapshot || busy || persistentValidation) return;
    void (async () => {
      const next = await run(() => executePersistentPlan(snapshot, persistentDrafts));
      if (!next) return;
      setPersistentDrafts(draftFromSlots(next.slots.filter((slot) => slot.kind === "persistent")));
      setPersistentDirty(false);
    })();
  }, [snapshot, busy, persistentValidation, persistentDrafts, run, executePersistentPlan]);

  const applyGeneral = useCallback(() => {
    if (!snapshot || !workspacePool || busy) return;
    const count = Math.max(0, Math.min(targetWorkerCount, maxAutoWorkers));
    const ids = workerIds.slice(0, count);
    const gpu: GpuAccess = sharedGpuDefault
      && snapshot.mode === "remote"
      && snapshot.gpu.available
      ? "shared"
      : "none";
    const plan = presetPlan(workspacePool, ids, preset, gpu);
    void (async () => {
      const next = await run(() => executeWorkspacePlan(snapshot, plan));
      if (!next) return;
      setWorkerDrafts(draftFromSlots(next.slots.filter((slot) => slot.kind === "workspace")));
      setWorkersDirty(false);
      setGeneralDirty(false);
    })();
  }, [snapshot, workspacePool, busy, targetWorkerCount, maxAutoWorkers, workerIds, sharedGpuDefault, preset, run, executeWorkspacePlan]);

  if (!snapshot || !workspacePool || !persistentPool) {
    return (
      <main className="connection-screen">
        <div className="connection-mark">L</div>
        <strong>{error ? "サービスに接続できません" : "接続中"}</strong>
        <p>{error ?? "Liaison Serviceを確認しています。"}</p>
        <button type="button" onClick={() => void refresh()}>再接続</button>
      </main>
    );
  }

  const managedCpu = workspacePool.cpu_capacity_threads + persistentPool.cpu_capacity_threads;
  const managedMemory = workspacePool.memory_capacity_mib + persistentPool.memory_capacity_mib;
  const reservedCpu = Math.max(0, snapshot.host_cpu_threads - managedCpu);
  const reservedMemory = Math.max(0, snapshot.host.memory_total_mib - managedMemory);
  const updatedAt = new Date(snapshot.updated_at_unix_ms).toLocaleTimeString("ja-JP", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit"
  });

  return (
    <div className={`app-shell ${busy ? "busy" : ""}`}>
      <header className="topbar">
        <div className="brand"><span>L</span><strong>Liaison</strong></div>
        <div className="top-status">
          <span className={snapshot.service_online ? "status-dot online" : "status-dot"} />
          <span>{snapshot.runtime === "wsl-docker" ? "Production" : "Mock"}</span>
          <span>更新 {updatedAt}</span>
        </div>
      </header>

      <main className="settings-layout">
        <aside className="settings-sidebar">
          <div className="sidebar-heading">
            <strong>設定</strong>
            <span>マシンとワークロード</span>
          </div>
          <nav aria-label="設定カテゴリ">
            {(Object.keys(sectionLabels) as SettingsSection[]).map((item) => (
              <button
                key={item}
                type="button"
                className={section === item ? "selected" : ""}
                onClick={() => setSection(item)}
              >
                <span>{sectionLabels[item].title}</span>
                <small>{item === "workers" ? `${activeWorkerCount}/${workerIds.length}` : ""}</small>
              </button>
            ))}
          </nav>
          <div className="sidebar-footer">
            <span>Service {snapshot.service_version}</span>
            <span>{snapshot.auto_tuned ? "Auto tuned" : "Fixed pools"}</span>
          </div>
        </aside>

        <section className="settings-content">
          <header className="content-heading">
            <div>
              <h1>{sectionLabels[section].title}</h1>
              <p>{sectionLabels[section].description}</p>
            </div>
            {busy && <span className="saving-indicator">適用中…</span>}
          </header>

          {section === "general" && (
            <div className="settings-page general-page">
              <section className="settings-group">
                <header><h2>マシン概要</h2><span>起動時に自動検出</span></header>
                <div className="summary-grid">
                  <div><span>CPU</span><strong>{snapshot.host_cpu_threads} threads</strong><small>{reservedCpu} threadsをWindows用に確保</small></div>
                  <div><span>RAM</span><strong>{formatGiB(snapshot.host.memory_total_mib)}</strong><small>{formatGiB(reservedMemory)}をWindows用に確保</small></div>
                  <div><span>GPU</span><strong>{snapshot.gpu.available ? "利用可能" : "未検出"}</strong><small>{snapshot.gpu.available ? formatGiB(snapshot.gpu.memory_total_mib) : "NVIDIA GPUを確認できません"}</small></div>
                  <div><span>Managed</span><strong>{managedCpu} CPU · {formatGiB(managedMemory)}</strong><small>P/Wプール合計</small></div>
                </div>
              </section>

              <section className="settings-group">
                <header><h2>運用モード</h2><span>変更は即時反映</span></header>
                <div className="mode-options">
                  {(Object.keys(modeLabels) as Mode[]).map((mode) => (
                    <button
                      key={mode}
                      type="button"
                      className={snapshot.mode === mode ? "selected" : ""}
                      disabled={busy}
                      onClick={() => setMode(mode)}
                    >
                      <strong>{modeLabels[mode]}</strong>
                      <small>{mode === "remote" ? "WプールとGPUを利用" : mode === "class" ? "Wプールを制限" : mode === "local_exclusive" ? "Wを停止、Pを維持" : "全スロットを停止"}</small>
                    </button>
                  ))}
                </div>
              </section>

              <section className="settings-group">
                <header><h2>自動配分</h2><span>よく使う構成をまとめて適用</span></header>
                <div className="form-rows">
                  <label className="form-row">
                    <span><strong>プリセット</strong><small>CPUとRAMの配分方法</small></span>
                    <select
                      value={preset}
                      disabled={busy}
                      onChange={(event: React.ChangeEvent<HTMLSelectElement>) => { setPreset(event.target.value as AllocationPreset); setGeneralDirty(true); }}
                    >
                      <option value="balanced">Balanced — 均等に全容量を使用</option>
                      <option value="performance">Performance — W1を優先</option>
                      <option value="headroom">Headroom — 25%の余裕を残す</option>
                    </select>
                  </label>
                  <label className="form-row">
                    <span><strong>Worker数</strong><small>有効にするWスロット数</small></span>
                    <div className="number-with-range">
                      <input
                        type="range"
                        min={0}
                        max={maxAutoWorkers}
                        step={1}
                        value={targetWorkerCount}
                        disabled={busy || snapshot.mode === "local_exclusive" || snapshot.mode === "maintenance"}
                        onChange={(event: React.ChangeEvent<HTMLInputElement>) => { setTargetWorkerCount(Number(event.target.value)); setGeneralDirty(true); }}
                      />
                      <input
                        type="number"
                        min={0}
                        max={maxAutoWorkers}
                        value={targetWorkerCount}
                        disabled={busy || snapshot.mode === "local_exclusive" || snapshot.mode === "maintenance"}
                        onChange={(event: React.ChangeEvent<HTMLInputElement>) => { setTargetWorkerCount(Math.max(0, Math.min(maxAutoWorkers, Number(event.target.value)))); setGeneralDirty(true); }}
                      />
                    </div>
                  </label>
                  <label className="form-row switch-row">
                    <span><strong>GPU Sharedを既定にする</strong><small>有効なworkerへGPUアクセスを付与</small></span>
                    <input
                      type="checkbox"
                      checked={sharedGpuDefault}
                      disabled={busy || snapshot.mode !== "remote" || !snapshot.gpu.available}
                      onChange={(event: React.ChangeEvent<HTMLInputElement>) => { setSharedGpuDefault(event.target.checked); setGeneralDirty(true); }}
                    />
                  </label>
                </div>
                <div className="group-actions">
                  <button type="button" className="primary-button" disabled={busy || !generalDirty} onClick={applyGeneral}>この構成を適用</button>
                </div>
              </section>
            </div>
          )}

          {section === "workers" && (
            <div className="settings-page table-page">
              <section className="usage-strip">
                <div><span>有効</span><strong>{workerTotals.enabled} / {workerIds.length}</strong></div>
                <div><span>CPU</span><strong>{workerTotals.cpu} / {workspacePool.cpu_capacity_threads}</strong></div>
                <div><span>RAM</span><strong>{formatGiB(workerTotals.memory)} / {formatGiB(workspacePool.memory_capacity_mib)}</strong></div>
                <p className={workerValidation ? "invalid" : ""}>{workerValidation ?? "各行を編集してから適用してください。"}</p>
              </section>

              <section className="config-table" aria-label="Worker設定">
                <div className="table-header">
                  <span>有効</span><span>Worker</span><span>CPU threads</span><span>RAM (GB)</span><span>GPU</span><span>状態</span>
                </div>
                {workers.map((slot) => {
                  const draft = workerDrafts[slot.id] ?? { enabled: false, cpu_threads: 1, memory_mib: 512, gpu: "none" as GpuAccess };
                  return (
                    <div className={`table-row ${draft.enabled ? "enabled" : ""}`} key={slot.id}>
                      <label className="checkbox-cell"><input type="checkbox" checked={draft.enabled} disabled={busy || snapshot.mode === "local_exclusive" || snapshot.mode === "maintenance"} onChange={(event: React.ChangeEvent<HTMLInputElement>) => updateWorkerDraft(slot.id, { enabled: event.target.checked })} /></label>
                      <div className="slot-name"><strong>{slot.id}</strong><small>{slot.endpoint ?? "未起動"}</small></div>
                      <input type="number" min={MIN_CPU} max={workspacePool.cpu_capacity_threads} step={1} value={draft.cpu_threads} disabled={busy || !draft.enabled} onChange={(event: React.ChangeEvent<HTMLInputElement>) => updateWorkerDraft(slot.id, { cpu_threads: Math.max(0, Math.round(Number(event.target.value))) })} />
                      <input type="number" min={0.5} max={workspacePool.memory_capacity_mib / 1024} step={0.5} value={draft.memory_mib / 1024} disabled={busy || !draft.enabled} onChange={(event: React.ChangeEvent<HTMLInputElement>) => updateWorkerDraft(slot.id, { memory_mib: Math.max(0, Math.round(Number(event.target.value) * 2) * 512) })} />
                      <select value={draft.gpu} disabled={busy || !draft.enabled || snapshot.mode !== "remote" || !snapshot.gpu.available} onChange={(event: React.ChangeEvent<HTMLSelectElement>) => updateWorkerDraft(slot.id, { gpu: event.target.value as GpuAccess })}>
                        <option value="shared">Shared</option><option value="exclusive">Exclusive</option><option value="none">Off</option>
                      </select>
                      <span className={`state-badge ${slot.status}`}>{slot.status}</span>
                    </div>
                  );
                })}
              </section>

              <footer className="page-actions">
                <button type="button" className="secondary-button" disabled={busy} onClick={balanceWorkerDrafts}>均等に割り当て</button>
                <div><button type="button" className="secondary-button" disabled={busy || !workersDirty} onClick={resetWorkers}>リセット</button><button type="button" className="primary-button" disabled={busy || !workersDirty || Boolean(workerValidation)} onClick={applyWorkers}>Workersへ適用</button></div>
              </footer>
            </div>
          )}

          {section === "persistent" && (
            <div className="settings-page table-page">
              <section className="usage-strip">
                <div><span>有効</span><strong>{persistentTotals.enabled} / {persistentIds.length}</strong></div>
                <div><span>CPU</span><strong>{persistentTotals.cpu} / {persistentPool.cpu_capacity_threads}</strong></div>
                <div><span>RAM</span><strong>{formatGiB(persistentTotals.memory)} / {formatGiB(persistentPool.memory_capacity_mib)}</strong></div>
                <p className={persistentValidation ? "invalid" : ""}>{persistentValidation ?? "P1・P2はGPUを使用しません。"}</p>
              </section>

              <section className="config-table persistent-table" aria-label="Persistent設定">
                <div className="table-header">
                  <span>有効</span><span>Slot</span><span>CPU threads</span><span>RAM (GB)</span><span>役割</span><span>状態</span>
                </div>
                {persistent.map((slot) => {
                  const draft = persistentDrafts[slot.id] ?? { enabled: false, cpu_threads: 1, memory_mib: 512, gpu: "none" as GpuAccess };
                  const unavailable = persistentPool.cpu_capacity_threads < 2 || persistentPool.memory_capacity_mib < 1024;
                  return (
                    <div className={`table-row ${draft.enabled ? "enabled" : ""}`} key={slot.id}>
                      <label className="checkbox-cell"><input type="checkbox" checked={draft.enabled} disabled={busy || unavailable} onChange={(event: React.ChangeEvent<HTMLInputElement>) => updatePersistentDraft(slot.id, { enabled: event.target.checked })} /></label>
                      <div className="slot-name"><strong>{slot.id}</strong><small>{slot.endpoint ?? "未起動"}</small></div>
                      <input type="number" min={MIN_CPU} max={Math.max(1, persistentPool.cpu_capacity_threads)} step={1} value={draft.cpu_threads} disabled={busy || !draft.enabled} onChange={(event: React.ChangeEvent<HTMLInputElement>) => updatePersistentDraft(slot.id, { cpu_threads: Math.max(0, Math.round(Number(event.target.value))) })} />
                      <input type="number" min={0.5} max={Math.max(0.5, persistentPool.memory_capacity_mib / 1024)} step={0.5} value={draft.memory_mib / 1024} disabled={busy || !draft.enabled} onChange={(event: React.ChangeEvent<HTMLInputElement>) => updatePersistentDraft(slot.id, { memory_mib: Math.max(0, Math.round(Number(event.target.value) * 2) * 512) })} />
                      <span className="role-label">常駐サービス</span>
                      <span className={`state-badge ${slot.status}`}>{slot.status}</span>
                    </div>
                  );
                })}
              </section>

              {persistentPool.cpu_capacity_threads === 0 && <div className="inline-notice">このマシンではPレイヤー用の安全な余裕を確保できないため、自動的に無効化されています。</div>}

              <footer className="page-actions"><span /><div><button type="button" className="secondary-button" disabled={busy || !persistentDirty} onClick={resetPersistent}>リセット</button><button type="button" className="primary-button" disabled={busy || !persistentDirty || Boolean(persistentValidation)} onClick={applyPersistent}>Persistentへ適用</button></div></footer>
            </div>
          )}

          {section === "runtime" && (
            <div className="settings-page runtime-page">
              <section className="settings-group">
                <header><h2>実行環境</h2><span>読み取り専用</span></header>
                <dl className="detail-list">
                  <div><dt>Runtime</dt><dd>{snapshot.runtime}</dd></div>
                  <div><dt>Service version</dt><dd>{snapshot.service_version}</dd></div>
                  <div><dt>Auto tune</dt><dd>{snapshot.auto_tuned ? "有効" : "無効"}</dd></div>
                  <div><dt>Tailscale</dt><dd>{snapshot.tailscale_online ? "Online" : "Offline"}</dd></div>
                  <div><dt>Control endpoint</dt><dd>Loopback / token authenticated</dd></div>
                </dl>
              </section>

              <section className="settings-group">
                <header><h2>現在の使用状況</h2><span>約3秒ごとに更新</span></header>
                <div className="meter-list">
                  <div><span><strong>Host CPU</strong><small>{formatPercent(snapshot.host.cpu_percent)}</small></span><progress max={100} value={snapshot.host.cpu_percent} /></div>
                  <div><span><strong>Host RAM</strong><small>{formatGiB(snapshot.host.memory_used_mib)} / {formatGiB(snapshot.host.memory_total_mib)}</small></span><progress max={snapshot.host.memory_total_mib || 1} value={snapshot.host.memory_used_mib} /></div>
                  <div><span><strong>GPU</strong><small>{snapshot.gpu.available ? `${formatPercent(snapshot.gpu.utilization_percent)} · ${formatGiB(snapshot.gpu.memory_used_mib)} / ${formatGiB(snapshot.gpu.memory_total_mib)}` : "未検出"}</small></span><progress max={100} value={snapshot.gpu.utilization_percent} /></div>
                </div>
              </section>

              <section className="settings-group">
                <header><h2>自動検出されたプール</h2><span>ホスト余力を除外</span></header>
                <dl className="detail-list">
                  <div><dt>Persistent pool</dt><dd>{persistentPool.cpu_capacity_threads} CPU · {formatGiB(persistentPool.memory_capacity_mib)}</dd></div>
                  <div><dt>Workspace pool</dt><dd>{workspacePool.cpu_capacity_threads} CPU · {formatGiB(workspacePool.memory_capacity_mib)}</dd></div>
                  <div><dt>Windows reserve</dt><dd>{reservedCpu} CPU · {formatGiB(reservedMemory)}</dd></div>
                  <div><dt>最大Worker数</dt><dd>{workerIds.length}</dd></div>
                </dl>
              </section>
            </div>
          )}

          {error && <div className="error-toast">{error}</div>}
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
