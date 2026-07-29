from pathlib import Path


PATH = Path("apps/liaison-installer/src/main.ts")
MARKER = "function localizeProgressStage(value: string): string"


def replace_required(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Expected one {label} replacement, found {count}")
    return text.replace(old, new, 1)


text = PATH.read_text(encoding="utf-8-sig")
if MARKER in text:
    print(f"{PATH}: progress localization already applied")
    raise SystemExit(0)

old_error = '''function cleanErrorMessage(value: string): string {
  return value
    .replace(/^Setup failed:\s*/i, "")
    .replace(/^Installation failed:\s*/i, "")
    .trim();
}'''
new_error = '''function cleanErrorMessage(value: string): string {
  const cleaned = value
    .replace(/^Setup failed:\s*/i, "")
    .replace(/^Installation failed:\s*/i, "")
    .trim();

  if (/LIAISON_FIRMWARE_VIRTUALIZATION_DISABLED/i.test(cleaned)) {
    return "BIOS/UEFIでCPU仮想化が無効です。Intel VT-x・Intel Virtualization Technology・AMD-V・SVMのいずれかを有効にし、Windowsを起動してから再試行してください。";
  }
  if (/LIAISON_CPU_VIRTUALIZATION_UNSUPPORTED/i.test(cleaned)) {
    return "このCPUまたは仮想マシンでは、WSL 2に必要な仮想化機能が利用できません。仮想マシンの場合はホスト側でネストされた仮想化を有効にしてください。";
  }
  if (/LIAISON_HYPERVISOR_RESTART_REQUIRED/i.test(cleaned)) {
    return "WSL 2に必要なWindows設定を修復しました。Windowsを再起動し、Liaison Setupを開いて同じ役割を再実行してください。";
  }
  if (/LIAISON_HYPERVISOR_NOT_RUNNING|HCS_E_HYPERV_NOT_INSTALLED/i.test(cleaned)) {
    return "Windowsハイパーバイザーが起動していません。仮想マシンプラットフォームとBIOS/UEFIの仮想化設定を確認し、Windowsを再起動してください。";
  }
  if (/official Ubuntu checksum list could not be parsed/i.test(cleaned)) {
    return "Ubuntuの公式チェックサム一覧を読み取れませんでした。ネットワークまたはプロキシを確認して再試行してください。";
  }
  if (/failed SHA-256 verification twice/i.test(cleaned)) {
    return "Ubuntuのダウンロード内容が公式ハッシュと一致しませんでした。プロキシやセキュリティソフトを確認してください。";
  }
  if (/Ubuntu import failed/i.test(cleaned)) {
    return "UbuntuをWSL 2へ登録できませんでした。Windowsの再起動後に再試行してください。";
  }
  if (/Ubuntu was imported but could not start/i.test(cleaned)) {
    return "Ubuntuは登録されましたが起動できませんでした。Windowsを再起動して再試行してください。";
  }
  if (/Server core exited with code -1/i.test(cleaned)) {
    return "サーバー設定プロセスが正常な終了コードを返しませんでした。技術情報をコピーして確認してください。";
  }
  return cleaned;
}'''
text = replace_required(text, old_error, new_error, "friendly error mapping")

localization = r'''
function localizeProgressStage(value: string): string {
  const labels: Record<string, string> = {
    "Setup launch": "セットアップを起動中",
    "Administrator approval": "管理者権限を確認中",
    "Payload check": "同梱ファイルを確認中",
    "Server setup": "サーバー設定を開始",
    "Dependency check": "必要な機能を確認中",
    "Virtualization check": "仮想化を確認中",
    "Virtualization repair": "Windows機能を修復中",
    "Hypervisor repair": "ハイパーバイザーを修復中",
    "Windows restart": "Windows再起動待ち",
    "Virtualization ready": "仮想化の準備完了",
    "WSL feature enable": "WSLを有効化中",
    "Ubuntu setup": "Ubuntuを準備中",
    "Ubuntu image": "Ubuntuを準備中",
    "Ubuntu checksum": "安全性を確認中",
    "Ubuntu download": "Ubuntuをダウンロード中",
    "Ubuntu cache check": "保存済みUbuntuを確認中",
    "Ubuntu verification": "Ubuntuを検証中",
    "Ubuntu redownload": "Ubuntuを再取得中",
    "Ubuntu import": "Ubuntuを登録中",
    "Ubuntu initialization": "Ubuntuを初期化中",
    "Ubuntu ready": "Ubuntuの準備完了",
    "Docker install": "Dockerを導入中",
    "Ubuntu packages": "必要なパッケージを取得中",
    "Docker startup": "Dockerを起動中",
    "Docker configuration": "Dockerを設定中",
    "Tailscale check": "Tailscaleを確認中",
    "Tailscale install": "Tailscaleを導入中",
    "Tailscale service": "Tailscaleを起動中",
    "Tailscale authentication": "Tailscaleの認証を開始",
    "Tailscale browser login": "ブラウザーでログイン",
    "Tailscale login pending": "Tailscaleのログイン待ち",
    "Tailscale ready": "Tailscaleの接続完了",
    "Tailscale deferred": "Tailscaleは後で設定可能",
    "Tailscale connection": "Tailscaleを接続中",
    "Liaison service": "Liaisonサービスを登録中",
    "Windows startup": "自動起動を設定中",
    "Server ready": "サーバーの準備完了",
    "Shortcut creation": "ショートカットを作成中",
    "Setup complete": "セットアップ完了"
  };
  return labels[value.trim()] ?? value.trim();
}

function localizeProgressDetail(value: string): string {
  const text = value.trim();
  if (/^\d+% - /.test(text)) return text;
  if (/Select Yes in the Windows permission prompt/i.test(text)) return "Windowsの確認画面が表示されたら「はい」を選択してください。";
  if (/Checking setup files and the current Windows state/i.test(text)) return "必要なファイルとWindowsの状態を確認しています。";
  if (/Checking the bundled Liaison application/i.test(text)) return "Liaison本体とセットアップ部品を確認しています。";
  if (/Preparing WSL, Ubuntu, Docker, Tailscale/i.test(text)) return "WSL、Ubuntu、Docker、Tailscale、Liaisonサービスを順番に準備します。";
  if (/Checking CPU virtualization, Windows features, and the hypervisor boot setting/i.test(text)) return "CPU仮想化、Windows機能、起動時のハイパーバイザー設定を確認しています。";
  if (/Enabling Windows feature/i.test(text)) return "WSL 2に必要なWindows機能を有効にしています。";
  if (/Enabling the Windows hypervisor at startup/i.test(text)) return "Windows起動時にハイパーバイザーが開始されるよう修復しています。";
  if (/Repairing the Windows hypervisor startup setting/i.test(text)) return "復元された起動設定を修復しています。";
  if (/Virtualization settings were repaired/i.test(text)) return "仮想化設定を修復しました。Windowsを再起動してください。";
  if (/Windows hypervisor is running and WSL 2 can be started/i.test(text)) return "Windowsハイパーバイザーが起動しており、WSL 2を開始できます。";
  if (/official Ubuntu 24\.04 LTS image/i.test(text)) return "Microsoft Storeを使わず、Ubuntu 24.04 LTSの公式イメージを使用します。";
  if (/official SHA-256 checksum/i.test(text)) return "公式SHA-256チェックサムを取得しています。操作は不要です。";
  if (/Verifying the saved Ubuntu image/i.test(text)) return "保存済みのUbuntuイメージを検証しています。";
  if (/matches the official SHA-256 checksum/i.test(text)) return "ダウンロード内容が公式ハッシュと一致するか確認しています。";
  if (/saved file was incomplete/i.test(text)) return "保存済みファイルが不完全だったため、自動で取得し直しています。";
  if (/Downloading the official image over HTTPS/i.test(text)) return "公式UbuntuイメージをHTTPSで取得しています。操作は不要です。";
  if (/Switching to the standard HTTPS download method/i.test(text)) return "別のHTTPS方式へ切り替えています。操作は不要です。";
  if (/Registering the verified image as a WSL 2 distribution/i.test(text)) return "検証済みイメージをWSL 2へ登録しています。操作は不要です。";
  if (/Starting Ubuntu for the first time/i.test(text)) return "Ubuntuを初めて起動して動作を確認しています。";
  if (/Ubuntu WSL started successfully/i.test(text)) return "Ubuntu WSLが正常に起動しました。";
  if (/Using the existing Ubuntu installation/i.test(text)) return "既存のUbuntuを使用します。";
  if (/Preparing Windows virtualization features/i.test(text)) return "Windowsの仮想化機能を準備しています。完了後に再起動が必要な場合があります。";
  if (/Installing Docker Engine inside Ubuntu/i.test(text)) return "Workerを実行するためのDocker EngineをUbuntuへ導入しています。";
  if (/Downloading packages required by Docker/i.test(text)) return "UbuntuからDockerの実行に必要な部品を取得しています。";
  if (/Configuring Docker Engine/i.test(text)) return "Docker Engineの設定と起動確認を行っています。";
  if (/Checking Tailscale for secure remote access/i.test(text)) return "安全なリモート接続に必要なTailscaleを確認しています。";
  if (/Downloading and installing the official Tailscale package/i.test(text)) return "公式TailscaleをWindowsへ導入しています。操作は不要です。";
  if (/Starting the Windows service/i.test(text)) return "Tailscaleサービスを起動し、自動起動を設定しています。";
  if (/Opening the browser sign-in page/i.test(text)) return "ブラウザーでログイン画面を開きます。";
  if (/Complete sign-in in the browser/i.test(text)) return "開いた画面でTailscaleへログインしてください。完了後は自動で続行します。";
  if (/Open the Tailscale app and complete sign-in/i.test(text)) return "通知領域のTailscaleを開いてログインしてください。";
  if (/Waiting for sign-in:/i.test(text)) return text.replace(/Waiting for sign-in:/i, "ログイン完了を待っています:").replace(/seconds/i, "秒");
  if (/Connection IP:/i.test(text)) return text.replace(/Connection IP:/i, "接続用IP:");
  if (/Tailscale can be signed in later/i.test(text)) return "Liaisonの導入は続行します。セットアップ後にTailscaleへログインできます。";
  if (/Registering the Liaison service/i.test(text)) return "Windows起動後も自動で動作するようにLiaisonサービスを登録しています。";
  if (/Configuring Liaison to start automatically/i.test(text)) return "Windowsへのサインイン後にLiaisonを自動起動する設定です。";
  if (/Creating Start menu and desktop shortcuts/i.test(text)) return "スタートメニューとデスクトップからLiaisonを開けるようにしています。";
  if (/Liaison is ready to launch/i.test(text)) return "Liaisonを起動できます。";
  if (/No action is required/i.test(text)) return text.replace(/No action is required\.?/i, "操作は不要です。");
  return text;
}

'''
text = replace_required(
    text,
    "function parseProgressEvents(text: string): ProgressEvent[] {",
    localization + "function parseProgressEvents(text: string): ProgressEvent[] {",
    "progress localization functions",
)
text = replace_required(
    text,
    "      stage: match[2].trim(),\n      detail: match[3].trim(),",
    "      stage: localizeProgressStage(match[2]),\n      detail: localizeProgressDetail(match[3]),",
    "localized progress event fields",
)

PATH.write_text(text, encoding="utf-8", newline="\n")
print(f"{PATH}: progress localization applied")
