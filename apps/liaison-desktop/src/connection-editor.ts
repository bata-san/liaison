import { invoke } from "@tauri-apps/api/core";

interface ConnectionSettings {
  address: string;
  token: string;
  path: string;
}

const DEFAULT_PORT = 57841;
let overlay: HTMLElement | null = null;
let settingsLoaded = false;

function normalizeAddress(value: string): string {
  const address = value.trim();
  if (!address) return address;
  if (address.startsWith("[") && address.includes("]")) {
    return /\]:\d+$/.test(address) ? address : `${address}:${DEFAULT_PORT}`;
  }
  if (!address.includes(":")) return `${address}:${DEFAULT_PORT}`;
  return address;
}

function parsePairingCode(value: string): { address: string; token: string } | null {
  const candidate = value.trim();
  if (!candidate) return null;
  try {
    const url = new URL(candidate);
    if (url.protocol !== "liaison:" || url.hostname !== "connect") return null;
    const address = normalizeAddress(url.searchParams.get("address") ?? "");
    const token = (url.searchParams.get("token") ?? "").trim();
    if (!address || token.length < 16) return null;
    return { address, token };
  } catch {
    return null;
  }
}

function setText(selector: string, value: string): void {
  const element = overlay?.querySelector<HTMLElement>(selector);
  if (element) element.textContent = value;
}

function getInput(selector: string): HTMLInputElement | null {
  return overlay?.querySelector<HTMLInputElement>(selector) ?? null;
}

function applyPairingCode(showError = true): boolean {
  const pairingInput = getInput("[data-connection-pairing]");
  const addressInput = getInput("[data-connection-address]");
  const tokenInput = getInput("[data-connection-token]");
  if (!pairingInput || !addressInput || !tokenInput) return false;
  const parsed = parsePairingCode(pairingInput.value);
  if (!parsed) {
    if (showError && pairingInput.value.trim()) {
      setText("[data-connection-status]", "ペアリングコードの形式が正しくありません。");
    }
    return false;
  }
  addressInput.value = parsed.address;
  tokenInput.value = parsed.token;
  setText("[data-connection-status]", "ペアリングコードを読み込みました。");
  return true;
}

function setBusy(busy: boolean): void {
  overlay?.querySelectorAll<HTMLButtonElement>("button").forEach((button) => {
    button.disabled = busy;
  });
  const status = overlay?.querySelector<HTMLElement>("[data-connection-status]");
  if (status) status.dataset.busy = busy ? "true" : "false";
}

async function loadSettings(): Promise<void> {
  if (settingsLoaded) return;
  settingsLoaded = true;
  try {
    const settings = await invoke<ConnectionSettings>("get_connection_settings");
    const address = getInput("[data-connection-address]");
    const token = getInput("[data-connection-token]");
    if (address) address.value = settings.address;
    if (token) token.value = settings.token;
    setText("[data-connection-path]", settings.path);
  } catch (reason) {
    setText("[data-connection-status]", `設定を読み込めませんでした: ${String(reason)}`);
  }
}

function retryReactConnection(): void {
  const retry = document.querySelector<HTMLButtonElement>(".connection-screen > button");
  retry?.click();
}

function createOverlay(): HTMLElement {
  const element = document.createElement("section");
  element.id = "liaison-connection-editor";
  element.hidden = true;
  element.innerHTML = `
    <div class="connection-editor-card" role="dialog" aria-labelledby="connection-editor-title">
      <div class="connection-editor-mark">L</div>
      <div class="connection-editor-heading">
        <strong id="connection-editor-title">サービスに接続できません</strong>
        <p data-connection-message></p>
      </div>
      <form class="connection-editor-form">
        <label>
          <span>ペアリングコード</span>
          <div class="connection-code-row">
            <input data-connection-pairing type="text" autocomplete="off" spellcheck="false" placeholder="liaison://connect?address=..." />
            <button data-apply-pairing type="button" class="connection-editor-small-button">読み込む</button>
          </div>
          <small>サーバーのセットアップ完了画面に表示された1行を貼り付けます。</small>
        </label>
        <div class="connection-divider"><span>または個別入力</span></div>
        <label>
          <span>サーバーIP / ホスト名</span>
          <input data-connection-address type="text" inputmode="url" autocomplete="off" spellcheck="false" placeholder="100.64.0.10 または server-name:57841" required />
          <small>ポートを省略すると ${DEFAULT_PORT} を使用します。</small>
        </label>
        <label>
          <span>接続トークン</span>
          <div class="connection-token-row">
            <input data-connection-token type="password" autocomplete="off" minlength="16" placeholder="サーバーで生成されたトークン" required />
            <button data-toggle-token type="button" class="connection-editor-small-button">表示</button>
          </div>
        </label>
        <p class="connection-editor-status" data-connection-status aria-live="polite"></p>
        <div class="connection-editor-actions">
          <button data-retry-connection type="button" class="connection-editor-secondary">再接続</button>
          <button type="submit" class="connection-editor-primary">保存して接続</button>
        </div>
      </form>
      <small class="connection-editor-path">保存先: <span data-connection-path>読み込み中</span></small>
    </div>
  `;

  const form = element.querySelector<HTMLFormElement>("form");
  form?.addEventListener("submit", (event) => {
    event.preventDefault();
    void (async () => {
      applyPairingCode(false);
      const addressInput = getInput("[data-connection-address]");
      const tokenInput = getInput("[data-connection-token]");
      if (!addressInput || !tokenInput) return;

      const address = normalizeAddress(addressInput.value);
      const token = tokenInput.value.trim();
      addressInput.value = address;
      if (!address || token.length < 16) {
        setText("[data-connection-status]", "ペアリングコード、またはIPと16文字以上の接続トークンを入力してください。");
        return;
      }

      setBusy(true);
      setText("[data-connection-status]", "接続設定を保存しています…");
      try {
        const path = await invoke<string>("save_connection", { address, token });
        setText("[data-connection-path]", path);
        setText("[data-connection-status]", "保存しました。新しい接続先を確認しています…");
        window.setTimeout(retryReactConnection, 100);
      } catch (reason) {
        setText("[data-connection-status]", String(reason));
      } finally {
        setBusy(false);
      }
    })();
  });

  element.querySelector<HTMLButtonElement>("[data-apply-pairing]")?.addEventListener("click", () => {
    applyPairingCode(true);
  });
  element.querySelector<HTMLInputElement>("[data-connection-pairing]")?.addEventListener("paste", () => {
    window.setTimeout(() => applyPairingCode(false), 0);
  });
  element.querySelector<HTMLButtonElement>("[data-retry-connection]")?.addEventListener("click", () => {
    setText("[data-connection-status]", "現在の設定で再接続しています…");
    retryReactConnection();
  });
  element.querySelector<HTMLButtonElement>("[data-toggle-token]")?.addEventListener("click", (event) => {
    const tokenInput = getInput("[data-connection-token]");
    const button = event.currentTarget as HTMLButtonElement;
    if (!tokenInput) return;
    const visible = tokenInput.type === "text";
    tokenInput.type = visible ? "password" : "text";
    button.textContent = visible ? "表示" : "隠す";
  });

  document.body.appendChild(element);
  return element;
}

function syncConnectionEditor(): void {
  const screen = document.querySelector<HTMLElement>(".connection-screen");
  const title = screen?.querySelector("strong")?.textContent?.trim() ?? "";
  const shouldShow = Boolean(screen && title === "サービスに接続できません");

  if (!overlay) overlay = createOverlay();
  overlay.hidden = !shouldShow;
  if (!shouldShow || !screen) return;

  const message = screen.querySelector("p")?.textContent?.trim() ?? "接続先を確認してください。";
  setText("[data-connection-message]", message);
  void loadSettings();
}

const observer = new MutationObserver(syncConnectionEditor);
observer.observe(document.documentElement, { childList: true, subtree: true, characterData: true });
window.addEventListener("DOMContentLoaded", syncConnectionEditor);
syncConnectionEditor();
