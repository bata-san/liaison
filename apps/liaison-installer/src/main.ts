import { invoke } from "@tauri-apps/api/core";
import "./styles.css";

type SetupRole = "server" | "client";
type ToastKind = "error" | "info";

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

const root = document.querySelector<HTMLDivElement>("#root")!;

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
    message: cleanErrorMessage(message) || "処理を完了できませんでした。セットアップログを確認してください。",
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

function render(): void {
  const completed = state.completed;
  const restart = state.restart_required;
  const failed = !busy && hasFailed(state);
  const message = state.message || (completed ? "セットアップは完了しています。" : "このPCの役割を選択してください。");
  const heading = completed
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
          <div class="toast-icon" aria-hidden="true">${toast.kind === "error" ? "!" : "i"}</div>
          <div class="toast-copy">
            <strong>${escapeHtml(toast.title)}</strong>
            <p>${escapeHtml(toast.message)}</p>
            ${toast.showLog && logText ? `<button id="toast-log-button" class="toast-log-button" type="button">セットアップログを見る</button>` : ""}
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
                <li>WorkerとPersistentスロットを提供</li>
                <li>Windows起動時に自動開始</li>
                <li>同じLiaison画面で管理</li>
              </ul>
            </button>

            <button class="role-card ${selectedRole === "client" ? "selected" : ""}" data-role="client" type="button" ${busy ? "disabled" : ""}>
              <span class="role-number">02</span>
              <div>
                <h2>クライアントとして設定</h2>
                <p>Tailscaleを準備し、サーバーのペアリングコードを入力できる状態にします。</p>
              </div>
              <ul>
                <li>サーバーへ安全に接続</li>
                <li>Worker管理とターミナルを利用</li>
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

      ${busy ? `
        <section class="progress-card" aria-live="polite">
          <div class="progress-bar"><span></span></div>
          <strong>必要な機能とソフトウェアを確認しています</strong>
          <p>管理者権限の確認が表示された場合は「はい」を選択してください。処理中にUbuntuやブラウザーが開くことがあります。</p>
        </section>
      ` : ""}

      ${logText ? `
        <details id="setup-log-card" class="log-card" ${completed ? "" : "open"}>
          <summary>セットアップログ</summary>
          <pre id="setup-log"></pre>
        </details>
      ` : ""}

      <footer class="setup-footer">
        <span>必要なPowerShellはLFへ正規化してからWSLへ渡します。</span>
        <span>Liaison 0.2.0</span>
      </footer>
    </div>
  `;

  const log = document.querySelector<HTMLElement>("#setup-log");
  if (log) log.textContent = logText;

  document.querySelector<HTMLButtonElement>("#toast-close-button")?.addEventListener("click", () => {
    toast = null;
    render();
  });
  document.querySelector<HTMLButtonElement>("#toast-log-button")?.addEventListener("click", () => {
    const details = document.querySelector<HTMLDetailsElement>("#setup-log-card");
    if (!details) return;
    details.open = true;
    details.scrollIntoView({ behavior: "smooth", block: "center" });
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
}

async function loadState(): Promise<void> {
  try {
    state = await invoke<SetupState>("get_setup_state");
    if (state.role) selectedRole = state.role;
    if (hasFailed(state)) {
      try {
        logText = await invoke<string>("get_setup_log");
      } catch {
        logText = "";
      }
      showErrorToast(state.message);
    } else if (state.restart_required) {
      showRestartToast(state.message);
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
    message: "セットアップを開始しています。",
    updated_at_unix: 0
  };
  render();

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
