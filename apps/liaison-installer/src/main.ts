import { invoke } from "@tauri-apps/api/core";
import "./styles.css";

type SetupRole = "server" | "client";
type ToastKind = "error" | "info" | "warning";
type LogLevel = "error" | "warning" | "success" | "info";
type LogFilter = "all" | "warning" | "error";

interface SetupState {
  role: SetupRole | null;
  completed: boolean;
  restart_required: boolean;
  message: string;
  updated_at_unix: number;
}

interface SetupResult extends SetupState {
  log: string;
  dashboard_path: string | null;
}

interface ToastState {
  kind: ToastKind;
  title: string;
  message: string;
  showLog: boolean;
}

interface ProgressEvent {
  percent: number;
  stage: string;
  detail: string;
  timestamp: string;
}

interface ProgressSnapshot {
  percent: number;
  stage: string;
  detail: string;
  events: ProgressEvent[];
  elapsedSeconds: number;
  lineCount: number;
  warningCount: number;
  errorCount: number;
  successCount: number;
}

interface StageDefinition {
  percent: number;
  label: string;
}

const root = document.querySelector<HTMLDivElement>("#root")!;

const stages: Record<SetupRole, StageDefinition[]> = {
  server: [
    { percent: 2, label: "起動" },
    { percent: 8, label: "管理者権限" },
    { percent: 18, label: "WSL機能" },
    { percent: 24, label: "Ubuntu" },
    { percent: 34, label: "Docker確認" },
    { percent: 38, label: "Docker導入" },
    { percent: 58, label: "Tailscale" },
    { percent: 68, label: "サーバー設定" },
    { percent: 80, label: "自動起動" },
    { percent: 92, label: "ショートカット" },
    { percent: 100, label: "完了" }
  ],
  client: [
    { percent: 2, label: "起動" },
    { percent: 8, label: "管理者権限" },
    { percent: 18, label: "クライアント構成" },
    { percent: 22, label: "Tailscale確認" },
    { percent: 30, label: "Tailscale導入" },
    { percent: 40, label: "サービス起動" },
    { percent: 52, label: "ブラウザー認証" },
    { percent: 78, label: "接続確認" },
    { percent: 92, label: "ショートカット" },
    { percent: 100, label: "完了" }
  ]
};

let state: SetupState = {
  role: null,
  completed: false,
  restart_required: false,
  message: "",
  updated_at_unix: 0
};
let selectedRole: SetupRole = "server";
let localOnly = false;
let busy = false;
let logText = "";
let toast: ToastState | null = null;
let logFilter: LogFilter = "all";
let autoScroll = true;
let setupStartedAt = 0;
let logPollTimer: number | null = null;
let clockTimer: number | null = null;
let copyResetTimer: number | null = null;
let pollInFlight = false;
let copyFeedback = false;

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function roleLabel(role: SetupRole | null): string {
  if (role === "server") return "サーバー";
  if (role === "client") return "クライアント";
  return "未設定";
}

function hasFailed(value: SetupState): boolean {
  return value.role !== null
    && value.updated_at_unix > 0
    && !value.completed
    && !value.restart_required;
}

function cleanErrorMessage(value: string): string {
  return value
    .replace(/^Setup failed:\s*/i, "")
    .replace(/^Installation failed:\s*/i, "")
    .trim();
}

function showErrorToast(message: string): void {
  toast = {
    kind: "error",
    title: "セットアップに失敗しました",
    message: cleanErrorMessage(message) || "処理を完了できませんでした。詳細ログを確認してください。",
    showLog: true
  };
}

function showRestartToast(message: string): void {
  toast = {
    kind: "info",
    title: "Windowsの再起動が必要です",
    message,
    showLog: false
  };
}

function showTailscaleToast(): void {
  toast = {
    kind: "warning",
    title: "Tailscaleのログインが残っています",
    message: "Liaisonの導入は完了しています。Tailscaleアプリまたは開いたブラウザーでログインすると、ネットワーク接続を利用できます。",
    showLog: true
  };
}

function formatDuration(totalSeconds: number): string {
  const value = Math.max(0, Math.floor(totalSeconds));
  const hours = Math.floor(value / 3600);
  const minutes = Math.floor((value % 3600) / 60);
  const seconds = value % 60;
  if (hours > 0) return `${hours}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
  return `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
}

function formatTimestamp(value: string): string {
  if (!value) return "--:--:--";
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return value.slice(11, 19) || "--:--:--";
  return parsed.toLocaleTimeString("ja-JP", { hour12: false });
}

function parseProgressEvents(text: string): ProgressEvent[] {
  const events: ProgressEvent[] = [];
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/PROGRESS\|(\d{1,3})\|([^|]+)\|(.+)$/);
    if (!match) continue;
    const timestamp = line.match(/^(\d{4}-\d{2}-\d{2}T\S+)/)?.[1] ?? "";
    events.push({
      percent: Math.min(100, Math.max(0, Number.parseInt(match[1], 10))),
      stage: match[2].trim(),
      detail: match[3].trim(),
      timestamp
    });
  }
  return events;
}

function visibleLogLines(text: string): string[] {
  return text
    .split(/\r?\n/)
    .map((line) => line.trimEnd())
    .filter((line) => line.trim().length > 0 && !line.includes("PROGRESS|"));
}

function classifyLogLine(line: string): LogLevel {
  if (/setup failed|installation failed|administrator elevation failed|syntax error|exception|fatal|exit code [1-9]|failed sha-256/i.test(line)) {
    return "error";
  }
  if (/warning|needslogin|login.*pending|not completed|restart|required|waiting|retry|代替導入/i.test(line)) {
    return "warning";
  }
  if (/completed successfully|installation completed|setup completed|ready at|準備完了|接続完了|sha-256 verified|success/i.test(line)) {
    return "success";
  }
  return "info";
}

function currentElapsedSeconds(): number {
  return setupStartedAt > 0 ? (Date.now() - setupStartedAt) / 1000 : 0;
}

function getProgressSnapshot(): ProgressSnapshot {
  const events = parseProgressEvents(logText);
  const lines = visibleLogLines(logText);
  const levels = lines.map(classifyLogLine);
  const latest = events.at(-1);
  let percent = latest?.percent ?? (busy ? 1 : state.completed ? 100 : 0);
  let stage = latest?.stage ?? (busy ? "セットアップを起動" : state.completed ? "セットアップ完了" : "待機中");
  let detail = latest?.detail ?? (busy ? "PowerShellから工程情報が届くのを待っています。" : state.message);

  if (state.completed) {
    percent = 100;
    stage = "セットアップ完了";
    detail = state.message;
  } else if (!busy && hasFailed(state)) {
    stage = "エラーで停止";
    detail = cleanErrorMessage(state.message);
  } else if (state.restart_required) {
    stage = "Windows再起動待ち";
    detail = state.message;
  }

  return {
    percent,
    stage,
    detail,
    events,
    elapsedSeconds: currentElapsedSeconds(),
    lineCount: lines.length,
    warningCount: levels.filter((level) => level === "warning").length,
    errorCount: levels.filter((level) => level === "error").length,
    successCount: levels.filter((level) => level === "success").length
  };
}

function renderStageList(snapshot: ProgressSnapshot): string {
  const definitions = stages[state.role ?? selectedRole];
  let currentIndex = -1;
  definitions.forEach((definition, index) => {
    if (snapshot.percent >= definition.percent) currentIndex = index;
  });

  return definitions.map((definition, index) => {
    const status = snapshot.percent >= 100 || index < currentIndex
      ? "done"
      : index === currentIndex
        ? "current"
        : "pending";
    const icon = status === "done" ? "✓" : status === "current" ? "•" : "";
    return `
      <li class="stage-item stage-${status}">
        <span class="stage-marker">${icon}</span>
        <span>${escapeHtml(definition.label)}</span>
        <small>${definition.percent}%</small>
      </li>
    `;
  }).join("");
}

function renderRecentEvents(snapshot: ProgressSnapshot): string {
  const recent = snapshot.events.slice(-8).reverse();
  if (recent.length === 0) return `<p class="empty-progress">工程ログの出力を待っています。</p>`;
  return recent.map((event, index) => `
    <div class="event-row ${index === 0 && busy ? "event-current" : ""}">
      <time>${formatTimestamp(event.timestamp)}</time>
      <div>
        <strong>${escapeHtml(event.stage)}</strong>
        <p>${escapeHtml(event.detail)}</p>
      </div>
      <span>${event.percent}%</span>
    </div>
  `).join("");
}

function formatLogLine(rawLine: string): { time: string; message: string } {
  const timestampMatch = rawLine.match(/^(\d{4}-\d{2}-\d{2}T\S+)\s+(.*)$/);
  let time = "--:--:--";
  let message = rawLine;
  if (timestampMatch) {
    time = formatTimestamp(timestampMatch[1]);
    message = timestampMatch[2];
  }
  const commandMatch = message.match(/^COMMAND\|([^|]+)\|(.+)$/);
  if (commandMatch) message = `[${commandMatch[1]}] ${commandMatch[2]}`;
  return { time, message };
}

function renderLogLines(): string {
  const lines = visibleLogLines(logText)
    .filter((line) => {
      const level = classifyLogLine(line);
      if (logFilter === "warning") return level === "warning" || level === "error";
      if (logFilter === "error") return level === "error";
      return true;
    })
    .slice(-800);

  if (lines.length === 0) {
    return `<div class="log-empty">${logText ? "この条件に一致するログはありません。" : "ログの出力を待っています…"}</div>`;
  }

  return lines.map((line) => {
    const level = classifyLogLine(line);
    const formatted = formatLogLine(line);
    const levelText = level === "error" ? "ERR" : level === "warning" ? "WRN" : level === "success" ? "OK" : "INF";
    return `
      <div class="log-line log-${level}">
        <time>${escapeHtml(formatted.time)}</time>
        <span class="log-level">${levelText}</span>
        <code>${escapeHtml(formatted.message)}</code>
      </div>
    `;
  }).join("");
}

function renderMonitor(): string {
  const snapshot = getProgressSnapshot();
  return `
    <section class="monitor-card" aria-live="polite">
      <div class="monitor-header">
        <div>
          <span class="eyebrow">Live setup monitor</span>
          <h2 id="progress-stage">${escapeHtml(snapshot.stage)}</h2>
          <p id="progress-detail">${escapeHtml(snapshot.detail)}</p>
        </div>
        <div class="progress-percent" id="progress-percent">${snapshot.percent}%</div>
      </div>

      <div class="determinate-progress" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${snapshot.percent}">
        <span id="progress-fill" style="width: ${snapshot.percent}%"></span>
      </div>

      <div class="metric-grid">
        <div><span>経過時間</span><strong id="metric-elapsed">${formatDuration(snapshot.elapsedSeconds)}</strong></div>
        <div><span>ログ行数</span><strong id="metric-lines">${snapshot.lineCount}</strong></div>
        <div><span>正常</span><strong id="metric-success">${snapshot.successCount}</strong></div>
        <div><span>警告</span><strong id="metric-warnings">${snapshot.warningCount}</strong></div>
        <div><span>エラー</span><strong id="metric-errors">${snapshot.errorCount}</strong></div>
      </div>

      <div class="monitor-grid">
        <section class="stage-panel">
          <div class="panel-heading">
            <div><span class="eyebrow">Planned steps</span><h3>工程一覧</h3></div>
            <span>${roleLabel(state.role ?? selectedRole)}</span>
          </div>
          <ol id="stage-list" class="stage-list">${renderStageList(snapshot)}</ol>
        </section>

        <section class="event-panel">
          <div class="panel-heading">
            <div><span class="eyebrow">Recent activity</span><h3>直近の実行履歴</h3></div>
          </div>
          <div id="recent-events" class="event-list">${renderRecentEvents(snapshot)}</div>
        </section>
      </div>

      <section id="setup-log-card" class="live-log-card">
        <div class="log-toolbar">
          <div>
            <span class="eyebrow">PowerShell / WSL output</span>
            <h3>詳細ログ</h3>
          </div>
          <div class="log-actions">
            <div class="filter-group" aria-label="ログの絞り込み">
              <button type="button" data-log-filter="all" class="${logFilter === "all" ? "active" : ""}">全件</button>
              <button type="button" data-log-filter="warning" class="${logFilter === "warning" ? "active" : ""}">警告</button>
              <button type="button" data-log-filter="error" class="${logFilter === "error" ? "active" : ""}">エラー</button>
            </div>
            <button id="auto-scroll-button" class="utility-button ${autoScroll ? "active" : ""}" type="button">自動スクロール ${autoScroll ? "ON" : "OFF"}</button>
            <button id="copy-log-button" class="utility-button" type="button">${copyFeedback ? "コピーしました" : "ログをコピー"}</button>
          </div>
        </div>
        <div id="live-log" class="live-log" tabindex="0">${renderLogLines()}</div>
      </section>
    </section>
  `;
}

function render(): void {
  const completed = state.completed;
  const restart = state.restart_required;
  const failed = !busy && hasFailed(state);
  const message = state.message || (completed ? "セットアップは完了しています。" : "このPCの役割を選択してください。");
  const heading = busy
    ? "セットアップ実行中"
    : completed
      ? "セットアップ完了"
      : restart
        ? "再起動が必要です"
        : failed
          ? "セットアップに失敗しました"
          : "このPCの役割を選択";

  root.innerHTML = `
    ${toast ? `
      <div class="toast-region" aria-live="assertive" aria-atomic="true">
        <section class="setup-toast toast-${toast.kind}" role="${toast.kind === "error" ? "alert" : "status"}">
          <div class="toast-icon" aria-hidden="true">${toast.kind === "error" ? "!" : toast.kind === "warning" ? "△" : "i"}</div>
          <div class="toast-copy">
            <strong>${escapeHtml(toast.title)}</strong>
            <p>${escapeHtml(toast.message)}</p>
            ${toast.showLog && logText ? `<button id="toast-log-button" class="toast-log-button" type="button">詳細ログへ移動</button>` : ""}
          </div>
          <button id="toast-close-button" class="toast-close-button" type="button" aria-label="通知を閉じる">×</button>
        </section>
      </div>
    ` : ""}

    <div class="setup-shell ${busy ? "is-busy" : ""}">
      <header class="setup-header">
        <div class="brand"><span>L</span><strong>Liaison</strong></div>
        <div class="header-copy">
          <h1>${heading}</h1>
          <p>${escapeHtml(message)}</p>
        </div>
      </header>

      ${completed ? `
        <section class="complete-card">
          <div class="complete-icon">✓</div>
          <div>
            <span class="eyebrow">Configured role</span>
            <h2>${roleLabel(state.role)}</h2>
            <p>通常のLiaison画面を起動できます。役割を変更する場合は再セットアップを選択してください。</p>
          </div>
          <div class="complete-actions">
            <button id="launch-button" class="primary-button" type="button">Liaisonを起動</button>
            <button id="reset-button" class="secondary-button" type="button">役割を変更</button>
          </div>
        </section>
      ` : `
        <main class="setup-content">
          <section class="role-grid" aria-label="Liaisonの役割">
            <button class="role-card ${selectedRole === "server" ? "selected" : ""}" data-role="server" type="button" ${busy ? "disabled" : ""}>
              <span class="role-number">01</span>
              <div>
                <h2>サーバーとして設定</h2>
                <p>WSL、Ubuntu、Docker Engine、Tailscale、Liaison Serviceを自動で構成します。</p>
              </div>
              <ul>
                <li>Ubuntuのダウンロード量まで表示</li>
                <li>apt・Docker・WSL出力を逐次表示</li>
                <li>Windows起動時に自動開始</li>
              </ul>
            </button>

            <button class="role-card ${selectedRole === "client" ? "selected" : ""}" data-role="client" type="button" ${busy ? "disabled" : ""}>
              <span class="role-number">02</span>
              <div>
                <h2>クライアントとして設定</h2>
                <p>Tailscaleを準備し、サーバーのペアリングコードを入力できる状態にします。</p>
              </div>
              <ul>
                <li>Tailscaleの導入と認証を追跡</li>
                <li>ブラウザーログイン待ちを秒単位で表示</li>
                <li>接続先は後から変更可能</li>
              </ul>
            </button>
          </section>

          ${selectedRole === "server" ? `
            <label class="option-row">
              <span>
                <strong>このPCだけで使用する</strong>
                <small>Tailscaleを設定せず、ローカル接続だけにします。</small>
              </span>
              <input id="local-only" type="checkbox" ${localOnly ? "checked" : ""} ${busy ? "disabled" : ""} />
            </label>
          ` : ""}

          ${restart ? `
            <section class="restart-card">
              <strong>Windowsを再起動してください</strong>
              <p>WSLのWindows機能が有効になりました。再起動後にLiaison Setupを開き、同じ役割で続行してください。</p>
            </section>
          ` : ""}

          <section class="setup-actions">
            <div>
              <span class="eyebrow">Selected role</span>
              <strong>${roleLabel(selectedRole)}</strong>
            </div>
            <button id="start-button" class="primary-button" type="button" ${busy ? "disabled" : ""}>
              ${busy ? "セットアップ中…" : restart ? "再起動後に続行" : failed ? "セットアップを再試行" : "セットアップを開始"}
            </button>
          </section>
        </main>
      `}

      ${(busy || logText) ? renderMonitor() : ""}

      <footer class="setup-footer">
        <span>進捗率はPowerShellが記録した実工程から計算します。</span>
        <span>Liaison 0.2.0</span>
      </footer>
    </div>
  `;

  bindEvents();
  refreshMonitor();
}

function bindEvents(): void {
  document.querySelector<HTMLButtonElement>("#toast-close-button")?.addEventListener("click", () => {
    toast = null;
    render();
  });
  document.querySelector<HTMLButtonElement>("#toast-log-button")?.addEventListener("click", () => {
    document.querySelector<HTMLElement>("#setup-log-card")?.scrollIntoView({ behavior: "smooth", block: "start" });
  });

  document.querySelectorAll<HTMLButtonElement>("[data-role]").forEach((button) => {
    button.addEventListener("click", () => {
      selectedRole = button.dataset.role as SetupRole;
      render();
    });
  });

  document.querySelector<HTMLInputElement>("#local-only")?.addEventListener("change", (event) => {
    localOnly = (event.currentTarget as HTMLInputElement).checked;
  });

  document.querySelector<HTMLButtonElement>("#start-button")?.addEventListener("click", () => {
    void startSetup();
  });
  document.querySelector<HTMLButtonElement>("#launch-button")?.addEventListener("click", () => {
    void launchLiaison();
  });
  document.querySelector<HTMLButtonElement>("#reset-button")?.addEventListener("click", () => {
    void resetSetup();
  });

  document.querySelectorAll<HTMLButtonElement>("[data-log-filter]").forEach((button) => {
    button.addEventListener("click", () => {
      logFilter = button.dataset.logFilter as LogFilter;
      render();
    });
  });
  document.querySelector<HTMLButtonElement>("#auto-scroll-button")?.addEventListener("click", () => {
    autoScroll = !autoScroll;
    render();
  });
  document.querySelector<HTMLButtonElement>("#copy-log-button")?.addEventListener("click", () => {
    void copyLog();
  });
}

function refreshMonitor(): void {
  if (!document.querySelector<HTMLElement>(".monitor-card")) return;
  const snapshot = getProgressSnapshot();
  const setText = (selector: string, value: string): void => {
    const element = document.querySelector<HTMLElement>(selector);
    if (element) element.textContent = value;
  };

  setText("#progress-stage", snapshot.stage);
  setText("#progress-detail", snapshot.detail);
  setText("#progress-percent", `${snapshot.percent}%`);
  setText("#metric-elapsed", formatDuration(snapshot.elapsedSeconds));
  setText("#metric-lines", String(snapshot.lineCount));
  setText("#metric-success", String(snapshot.successCount));
  setText("#metric-warnings", String(snapshot.warningCount));
  setText("#metric-errors", String(snapshot.errorCount));

  const fill = document.querySelector<HTMLElement>("#progress-fill");
  if (fill) fill.style.width = `${snapshot.percent}%`;
  document.querySelector<HTMLElement>(".determinate-progress")?.setAttribute("aria-valuenow", String(snapshot.percent));

  const stageList = document.querySelector<HTMLElement>("#stage-list");
  if (stageList) stageList.innerHTML = renderStageList(snapshot);
  const events = document.querySelector<HTMLElement>("#recent-events");
  if (events) events.innerHTML = renderRecentEvents(snapshot);

  const log = document.querySelector<HTMLElement>("#live-log");
  if (log) {
    const nearBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 70;
    log.innerHTML = renderLogLines();
    if (autoScroll || nearBottom) log.scrollTop = log.scrollHeight;
  }
}

async function pollLiveLog(): Promise<void> {
  if (pollInFlight) return;
  pollInFlight = true;
  try {
    const next = await invoke<string>("get_setup_log");
    if (next !== logText) {
      logText = next;
      refreshMonitor();
    }
  } catch {
    // The elevated process may be replacing the file. Retry on the next poll.
  } finally {
    pollInFlight = false;
  }
}

function startLiveMonitoring(): void {
  stopLiveMonitoring();
  setupStartedAt = Date.now();
  logPollTimer = window.setInterval(() => { void pollLiveLog(); }, 450);
  clockTimer = window.setInterval(() => { refreshMonitor(); }, 1000);
  void pollLiveLog();
}

function stopLiveMonitoring(): void {
  if (logPollTimer !== null) window.clearInterval(logPollTimer);
  if (clockTimer !== null) window.clearInterval(clockTimer);
  logPollTimer = null;
  clockTimer = null;
}

async function copyLog(): Promise<void> {
  try {
    await navigator.clipboard.writeText(logText);
    copyFeedback = true;
    render();
    if (copyResetTimer !== null) window.clearTimeout(copyResetTimer);
    copyResetTimer = window.setTimeout(() => {
      copyFeedback = false;
      render();
    }, 1800);
  } catch (reason) {
    showErrorToast(`ログをコピーできませんでした: ${String(reason)}`);
    render();
  }
}

async function loadState(): Promise<void> {
  try {
    state = await invoke<SetupState>("get_setup_state");
    if (state.role) selectedRole = state.role;
    try {
      logText = await invoke<string>("get_setup_log");
    } catch {
      logText = "";
    }
    if (hasFailed(state)) {
      showErrorToast(state.message);
    } else if (state.restart_required) {
      showRestartToast(state.message);
    } else if (state.completed && logText.includes("LIAISON_TAILSCALE_LOGIN_REQUIRED")) {
      showTailscaleToast();
    }
  } catch (reason) {
    state.message = `セットアップ状態を読み込めませんでした: ${String(reason)}`;
    showErrorToast(state.message);
  }
  render();
}

async function startSetup(): Promise<void> {
  if (busy) return;
  busy = true;
  toast = null;
  logText = "";
  state = {
    ...state,
    role: selectedRole,
    completed: false,
    restart_required: false,
    message: "セットアップを開始しています。詳細な工程とログを下に表示します。",
    updated_at_unix: 0
  };
  render();
  startLiveMonitoring();

  try {
    const result = await invoke<SetupResult>("run_setup", {
      role: selectedRole,
      localOnly: selectedRole === "server" && localOnly
    });
    state = result;
    logText = result.log;
    if (!result.completed && !result.restart_required) {
      showErrorToast(result.message);
    } else if (result.restart_required) {
      showRestartToast(result.message);
    } else if (result.log.includes("LIAISON_TAILSCALE_LOGIN_REQUIRED")) {
      showTailscaleToast();
    }
  } catch (reason) {
    const message = String(reason);
    state = {
      role: selectedRole,
      completed: false,
      restart_required: false,
      message,
      updated_at_unix: Math.floor(Date.now() / 1000)
    };
    try {
      logText = await invoke<string>("get_setup_log");
    } catch {
      logText = "";
    }
    showErrorToast(message);
  } finally {
    await pollLiveLog();
    stopLiveMonitoring();
    busy = false;
    render();
  }
}

async function launchLiaison(): Promise<void> {
  try {
    await invoke("launch_liaison");
  } catch (reason) {
    state.message = `Liaisonを起動できませんでした: ${String(reason)}`;
    showErrorToast(state.message);
    render();
  }
}

async function resetSetup(): Promise<void> {
  try {
    await invoke("reset_setup_state");
    state = {
      role: null,
      completed: false,
      restart_required: false,
      message: "役割を選び直してください。",
      updated_at_unix: 0
    };
    setupStartedAt = 0;
    logText = "";
    toast = null;
    render();
  } catch (reason) {
    state.message = String(reason);
    showErrorToast(state.message);
    render();
  }
}

void loadState();
