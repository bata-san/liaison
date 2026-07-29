from pathlib import Path


MAIN_PATH = Path("apps/liaison-installer/src/main.ts")
STYLE_PATH = Path("apps/liaison-installer/src/styles.css")
MARKER = "function getUserAction(snapshot: ProgressSnapshot): string"
STYLE_MARKER = ".user-guidance-grid"


def replace_required(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Expected one {label} replacement, found {count}")
    return text.replace(old, new, 1)


main = MAIN_PATH.read_text(encoding="utf-8-sig")
if MARKER not in main:
    main = replace_required(
        main,
        'message: cleanErrorMessage(message) || "処理を完了できませんでした。詳細ログを確認してください。",',
        'message: cleanErrorMessage(message) || "処理を完了できませんでした。画面に表示された対処を確認してください。",',
        "error guidance",
    )

    main = replace_required(
        main,
        '${toast.showLog && logText ? `<button id="toast-log-button" class="toast-log-button" type="button">詳細ログへ移動</button>` : ""}',
        '${toast.showLog && logText ? `<button id="toast-log-button" class="toast-log-button" type="button">技術情報を開く</button>` : ""}',
        "toast log button",
    )

    insertion = r'''
function getUserAction(snapshot: ProgressSnapshot): string {
  if (state.completed) return "セットアップは完了しました。Liaisonを起動できます。";
  if (state.restart_required) return "Windowsを再起動してください。再起動後に同じセットアップを続行します。";
  if (!busy && hasFailed(state)) return "表示されたエラー内容を確認し、修正版のセットアップで再試行してください。";
  const value = `${snapshot.stage} ${snapshot.detail}`;
  if (/管理者権限/.test(value)) return "Windowsの確認画面が表示されたら「はい」を選択してください。";
  if (/ブラウザー|ログイン|認証/.test(value)) return "開いたブラウザーまたはTailscaleアプリでログインしてください。";
  return "操作は不要です。この画面を閉じずに待ってください。";
}

function getNextStep(snapshot: ProgressSnapshot): string {
  const value = `${snapshot.stage} ${snapshot.detail}`;
  if (/Ubuntu|WSL/.test(value)) return "確認後、Dockerを実行できるLinux環境を準備します。";
  if (/Docker|パッケージ/.test(value)) return "Dockerの起動確認後、Liaisonサービスを登録します。";
  if (/Tailscale/.test(value)) return "接続確認後、Liaisonの自動起動とショートカットを設定します。";
  if (/ショートカット|自動起動|サービス/.test(value)) return "最終確認後、Liaisonを起動できる状態になります。";
  if (state.completed) return "Liaisonを起動し、サーバーまたはクライアントの状態を確認します。";
  return "現在の工程が完了すると、次の工程へ自動で進みます。";
}

'''
    main = replace_required(
        main,
        "function renderStageList(snapshot: ProgressSnapshot): string {",
        insertion + "function renderStageList(snapshot: ProgressSnapshot): string {",
        "guidance functions",
    )

    old_metrics = '''      <div class="metric-grid">
        <div><span>経過時間</span><strong id="metric-elapsed">${formatDuration(snapshot.elapsedSeconds)}</strong></div>
        <div><span>ログ行数</span><strong id="metric-lines">${snapshot.lineCount}</strong></div>
        <div><span>正常</span><strong id="metric-success">${snapshot.successCount}</strong></div>
        <div><span>警告</span><strong id="metric-warnings">${snapshot.warningCount}</strong></div>
        <div><span>エラー</span><strong id="metric-errors">${snapshot.errorCount}</strong></div>
      </div>'''
    new_metrics = '''      <div class="user-guidance-grid">
        <section class="guidance-card guidance-primary">
          <span>いま行うこと</span>
          <strong id="user-action">${escapeHtml(getUserAction(snapshot))}</strong>
        </section>
        <section class="guidance-card">
          <span>次に起きること</span>
          <strong id="next-step">${escapeHtml(getNextStep(snapshot))}</strong>
        </section>
      </div>

      <div class="metric-grid metric-grid-compact">
        <div><span>経過時間</span><strong id="metric-elapsed">${formatDuration(snapshot.elapsedSeconds)}</strong></div>
        <div><span>警告</span><strong id="metric-warnings">${snapshot.warningCount}</strong></div>
        <div><span>エラー</span><strong id="metric-errors">${snapshot.errorCount}</strong></div>
      </div>'''
    main = replace_required(main, old_metrics, new_metrics, "monitor metrics")

    old_log = '''      <section id="setup-log-card" class="live-log-card">
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
      </section>'''
    new_log = '''      <details id="setup-log-card" class="technical-log-card" ${!busy && hasFailed(state) ? "open" : ""}>
        <summary>
          <span><strong>技術情報</strong><small>問題が起きたときやサポートへ共有するときだけ使用します。</small></span>
          <span>PowerShell / WSL</span>
        </summary>
        <section class="live-log-card">
          <div class="log-toolbar">
            <div>
              <span class="eyebrow">Technical output</span>
              <h3>内部ログ</h3>
            </div>
            <div class="log-actions">
              <div class="filter-group" aria-label="ログの絞り込み">
                <button type="button" data-log-filter="all" class="${logFilter === "all" ? "active" : ""}">全件</button>
                <button type="button" data-log-filter="warning" class="${logFilter === "warning" ? "active" : ""}">警告</button>
                <button type="button" data-log-filter="error" class="${logFilter === "error" ? "active" : ""}">エラー</button>
              </div>
              <button id="auto-scroll-button" class="utility-button ${autoScroll ? "active" : ""}" type="button">自動スクロール ${autoScroll ? "ON" : "OFF"}</button>
              <button id="copy-log-button" class="utility-button" type="button">${copyFeedback ? "コピーしました" : "技術ログをコピー"}</button>
            </div>
          </div>
          <div id="live-log" class="live-log" tabindex="0">${renderLogLines()}</div>
        </section>
      </details>'''
    main = replace_required(main, old_log, new_log, "technical log panel")

    main = replace_required(
        main,
        '<li>apt・Docker・WSL出力を逐次表示</li>',
        '<li>現在の作業と必要な操作を分かりやすく表示</li>',
        "server role copy",
    )
    main = replace_required(
        main,
        'message: "セットアップを開始しています。詳細な工程とログを下に表示します。",',
        'message: "セットアップを開始しています。現在の作業と必要な操作を下に表示します。",',
        "start message",
    )

    old_click = '''  document.querySelector<HTMLButtonElement>("#toast-log-button")?.addEventListener("click", () => {
    document.querySelector<HTMLElement>("#setup-log-card")?.scrollIntoView({ behavior: "smooth", block: "start" });
  });'''
    new_click = '''  document.querySelector<HTMLButtonElement>("#toast-log-button")?.addEventListener("click", () => {
    const details = document.querySelector<HTMLDetailsElement>("#setup-log-card");
    if (!details) return;
    details.open = true;
    details.scrollIntoView({ behavior: "smooth", block: "start" });
  });'''
    main = replace_required(main, old_click, new_click, "technical log open handler")

    main = replace_required(
        main,
        '  setText("#progress-percent", `${snapshot.percent}%`);',
        '  setText("#progress-percent", `${snapshot.percent}%`);\n  setText("#user-action", getUserAction(snapshot));\n  setText("#next-step", getNextStep(snapshot));',
        "monitor guidance refresh",
    )

    MAIN_PATH.write_text(main, encoding="utf-8", newline="\n")
    print(f"{MAIN_PATH}: guidance UX applied")
else:
    print(f"{MAIN_PATH}: guidance UX already applied")

styles = STYLE_PATH.read_text(encoding="utf-8-sig")
if STYLE_MARKER not in styles:
    styles += r'''

.user-guidance-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px;
  margin-top: 16px;
}
.guidance-card {
  min-height: 92px;
  padding: 16px 18px;
  border: 1px solid #e4e4e7;
  border-radius: 13px;
  background: #fafafa;
}
.guidance-card span {
  display: block;
  margin-bottom: 7px;
  color: #71717a;
  font-size: 11px;
  font-weight: 700;
}
.guidance-card strong {
  display: block;
  color: #27272a;
  font-size: 14px;
  line-height: 1.55;
}
.guidance-primary {
  border-color: #a1a1aa;
  background: white;
  box-shadow: 0 5px 18px rgba(24,24,27,.05);
}
.metric-grid-compact { grid-template-columns: repeat(3, minmax(0, 1fr)); }
.technical-log-card {
  margin-top: 16px;
  overflow: hidden;
  border: 1px solid #d4d4d8;
  border-radius: 14px;
  background: white;
}
.technical-log-card > summary {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 18px;
  padding: 16px 18px;
  cursor: pointer;
  list-style: none;
  color: #3f3f46;
}
.technical-log-card > summary::-webkit-details-marker { display: none; }
.technical-log-card > summary:hover { background: #fafafa; }
.technical-log-card > summary > span:first-child { display: grid; gap: 4px; }
.technical-log-card > summary strong { font-size: 13px; }
.technical-log-card > summary small { color: #71717a; font-size: 11px; font-weight: 400; }
.technical-log-card > summary > span:last-child { color: #a1a1aa; font: 10px ui-monospace, SFMono-Regular, Consolas, monospace; }
.technical-log-card[open] > summary { border-bottom: 1px solid #d4d4d8; }
.technical-log-card .live-log-card { margin-top: 0; border: 0; border-radius: 0; }

@media (max-width: 920px) {
  .user-guidance-grid { grid-template-columns: 1fr; }
}
'''
    STYLE_PATH.write_text(styles, encoding="utf-8", newline="\n")
    print(f"{STYLE_PATH}: guidance styles applied")
else:
    print(f"{STYLE_PATH}: guidance styles already applied")
