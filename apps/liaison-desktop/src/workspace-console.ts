import { invoke } from "@tauri-apps/api/core";

interface SlotSummary {
  id: string;
  kind: "persistent" | "workspace";
  status: "stopped" | "starting" | "running" | "throttled" | "draining" | "error";
}

interface SystemSnapshot {
  slots: SlotSummary[];
}

interface CommandOutput {
  slot_id: string;
  command: string;
  working_directory: string;
  exit_code: number;
  stdout: string;
  stderr: string;
  truncated: boolean;
}

interface HistoryEntry {
  slotId: string;
  directory: string;
  command: string;
  output?: CommandOutput;
  error?: string;
  timestamp: Date;
}

let panel: HTMLElement | null = null;
let launcher: HTMLButtonElement | null = null;
let history: HistoryEntry[] = [];
let running = false;

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function activeWorkspaceSlots(snapshot: SystemSnapshot): SlotSummary[] {
  return snapshot.slots
    .filter((slot) => slot.kind === "workspace" && slot.status !== "stopped")
    .sort((left, right) => left.id.localeCompare(right.id));
}

function setStatus(message: string, failed = false): void {
  const status = panel?.querySelector<HTMLElement>("[data-workspace-status]");
  if (!status) return;
  status.textContent = message;
  status.dataset.failed = failed ? "true" : "false";
}

function setRunning(value: boolean): void {
  running = value;
  panel?.querySelectorAll<HTMLButtonElement>("button").forEach((button) => {
    if (!button.matches("[data-close-workspace]")) button.disabled = value;
  });
  panel
    ?.querySelectorAll<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>(
      "input, textarea, select"
    )
    .forEach((input) => {
      input.disabled = value;
    });
}

function renderHistory(): void {
  const terminal = panel?.querySelector<HTMLElement>("[data-workspace-terminal]");
  if (!terminal) return;
  if (history.length === 0) {
    terminal.innerHTML =
      '<div class="workspace-empty-output">コマンドを実行すると、ここに結果が表示されます。</div>';
    return;
  }

  terminal.innerHTML = history
    .map((entry) => {
      const time = entry.timestamp.toLocaleTimeString("ja-JP", {
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit"
      });
      const prompt = `${entry.slotId}:${entry.directory}$ ${entry.command}`;
      if (entry.error) {
        return `
          <article class="workspace-output-entry failed">
            <header><span>${escapeHtml(time)}</span><code>${escapeHtml(prompt)}</code></header>
            <pre class="stderr">${escapeHtml(entry.error)}</pre>
          </article>`;
      }
      const output = entry.output;
      if (!output) return "";
      return `
        <article class="workspace-output-entry ${output.exit_code === 0 ? "" : "failed"}">
          <header>
            <span>${escapeHtml(time)}</span>
            <code>${escapeHtml(prompt)}</code>
            <small>exit ${output.exit_code}${output.truncated ? " · truncated" : ""}</small>
          </header>
          ${output.stdout ? `<pre>${escapeHtml(output.stdout)}</pre>` : ""}
          ${output.stderr ? `<pre class="stderr">${escapeHtml(output.stderr)}</pre>` : ""}
        </article>`;
    })
    .join("");
  terminal.scrollTop = terminal.scrollHeight;
}

async function refreshSlots(): Promise<void> {
  const select = panel?.querySelector<HTMLSelectElement>("[data-workspace-slot]");
  if (!select) return;
  const previous = select.value;
  try {
    const snapshot = await invoke<SystemSnapshot>("get_snapshot");
    const slots = activeWorkspaceSlots(snapshot);
    select.innerHTML = slots.length
      ? slots
          .map((slot) => `<option value="${slot.id}">${slot.id} · ${slot.status}</option>`)
          .join("")
      : '<option value="">起動中のWorkerがありません</option>';
    if (slots.some((slot) => slot.id === previous)) select.value = previous;
    setStatus(
      slots.length
        ? `${slots.length}個のWorkerを操作できます。`
        : "Workers設定でW1〜W5を1つ以上起動してください。",
      slots.length === 0
    );
  } catch (reason) {
    select.innerHTML = '<option value="">サーバーへ接続できません</option>';
    setStatus(String(reason), true);
  }
}

async function executeCommand(commandOverride?: string): Promise<void> {
  if (running) return;
  const slot = panel?.querySelector<HTMLSelectElement>("[data-workspace-slot]")?.value ?? "";
  const directory =
    panel?.querySelector<HTMLInputElement>("[data-workspace-directory]")?.value.trim() ||
    "/workspace";
  const commandInput = panel?.querySelector<HTMLTextAreaElement>("[data-workspace-command]");
  const command = (commandOverride ?? commandInput?.value ?? "").trim();

  if (!slot) {
    setStatus("起動中のWorkerを選択してください。", true);
    return;
  }
  if (!command) {
    setStatus("実行するコマンドを入力してください。", true);
    return;
  }

  setRunning(true);
  setStatus(`${slot}で実行しています…`);
  try {
    const output = await invoke<CommandOutput>("run_workspace_command", {
      slotId: slot,
      command,
      workingDirectory: directory
    });
    history.push({ slotId: slot, directory, command, output, timestamp: new Date() });
    setStatus(`完了しました。終了コード: ${output.exit_code}`, output.exit_code !== 0);
    if (commandInput && !commandOverride) commandInput.value = "";
  } catch (reason) {
    const error = String(reason);
    history.push({ slotId: slot, directory, command, error, timestamp: new Date() });
    setStatus(error, true);
  } finally {
    setRunning(false);
    renderHistory();
    commandInput?.focus();
  }
}

function closePanel(): void {
  if (panel) panel.hidden = true;
}

function openPanel(): void {
  if (!panel) panel = createPanel();
  panel.hidden = false;
  void refreshSlots();
  panel.querySelector<HTMLTextAreaElement>("[data-workspace-command]")?.focus();
}

function createPanel(): HTMLElement {
  const element = document.createElement("section");
  element.id = "liaison-workspace-panel";
  element.hidden = true;
  element.innerHTML = `
    <div class="workspace-panel-shell" role="dialog" aria-labelledby="workspace-panel-title">
      <header class="workspace-panel-header">
        <div>
          <strong id="workspace-panel-title">作業環境</strong>
          <span>WorkerコンテナをLiaisonから直接操作</span>
        </div>
        <button type="button" data-close-workspace aria-label="閉じる">×</button>
      </header>
      <div class="workspace-toolbar">
        <label>
          <span>Worker</span>
          <select data-workspace-slot></select>
        </label>
        <label class="workspace-directory-field">
          <span>作業ディレクトリ</span>
          <input data-workspace-directory value="/workspace" spellcheck="false" />
        </label>
        <button type="button" data-refresh-workspaces class="workspace-secondary">更新</button>
      </div>
      <div class="workspace-quick-actions">
        <button type="button" data-workspace-quick="pwd">現在地</button>
        <button type="button" data-workspace-quick="ls -la">ファイル一覧</button>
        <button type="button" data-workspace-quick="git status --short --branch">Git状態</button>
        <button type="button" data-workspace-clear>出力を消去</button>
      </div>
      <div class="workspace-terminal" data-workspace-terminal></div>
      <form class="workspace-command-form">
        <label>
          <span>コマンド</span>
          <textarea data-workspace-command rows="3" spellcheck="false" placeholder="例: python3 main.py"></textarea>
        </label>
        <div class="workspace-command-footer">
          <p data-workspace-status aria-live="polite"></p>
          <button type="submit" class="workspace-primary">実行</button>
        </div>
      </form>
      <footer>Ctrl+Enterでも実行できます。コマンドは選択したWorker内の /workspace 以下で実行されます。</footer>
    </div>`;

  element.querySelector("[data-close-workspace]")?.addEventListener("click", closePanel);
  element.querySelector("[data-refresh-workspaces]")?.addEventListener("click", () => {
    void refreshSlots();
  });
  element.querySelector("[data-workspace-clear]")?.addEventListener("click", () => {
    history = [];
    renderHistory();
    setStatus("出力履歴を消去しました。");
  });
  element.querySelectorAll<HTMLButtonElement>("[data-workspace-quick]").forEach((button) => {
    button.addEventListener("click", () => void executeCommand(button.dataset.workspaceQuick));
  });
  element.querySelector("form")?.addEventListener("submit", (event) => {
    event.preventDefault();
    void executeCommand();
  });
  element
    .querySelector<HTMLTextAreaElement>("[data-workspace-command]")
    ?.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
        event.preventDefault();
        void executeCommand();
      }
    });

  document.body.appendChild(element);
  renderHistory();
  return element;
}

function installLauncher(): void {
  const topbar = document.querySelector<HTMLElement>(".topbar");
  if (!topbar || launcher) return;
  launcher = document.createElement("button");
  launcher.type = "button";
  launcher.className = "workspace-launcher";
  launcher.textContent = "作業環境";
  launcher.addEventListener("click", openPanel);
  const status = topbar.querySelector(".top-status");
  if (status) topbar.insertBefore(launcher, status);
  else topbar.appendChild(launcher);
}

const observer = new MutationObserver(() => installLauncher());
observer.observe(document.documentElement, { childList: true, subtree: true });
window.addEventListener("DOMContentLoaded", installLauncher);
installLauncher();
