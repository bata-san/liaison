# Liaison

Liaisonは、WindowsワークステーションのCPU・RAM・GPUを、PersistentスロットとWorkspaceスロットへ割り当てる軽量な管理ツールです。

## いちばん簡単な使い方

Liaisonは2つに分かれています。

- **Server版**: 管理対象のWindows PCへ入れます。WSL・Docker・GPUを操作します。
- **Client版**: 操作用PCへ入れます。設定画面だけを提供します。

配布ZIPには実行ファイルが含まれるため、セットアップ先PCにRustやNode.jsは不要です。

### 1. 配布ZIPを作る

開発PCで1回だけ実行します。

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-distributions.ps1
```

次の2ファイルが作られます。

```text
dist\liaison-server-windows.zip
dist\liaison-client-windows.zip
```

### 2. Server版をセットアップ

`liaison-server-windows.zip`をサーバーPCで展開し、管理者PowerShellで実行します。

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup-server.ps1
```

セットアップが自動で行うこと:

- マシンスペックの検出とリソース自動調整
- サーバーファイルと設定の配置
- 強いランダムトークンの生成
- ログオン時の自動起動登録
- WSLとDockerの確認
- Tailscale IPの自動検出
- Tailscale専用のファイアウォールとポート転送
- サーバー疎通確認
- デスクトップへの`liaison-client.json`生成

Tailscaleがない場合は、そのサーバーPC内だけから接続できるローカル構成になります。

### 3. Client版をセットアップ

`liaison-client-windows.zip`をクライアントPCで展開します。

サーバーPCのデスクトップに作成された`liaison-client.json`を、クライアント版フォルダーの直下へコピーします。

通常のPowerShellで実行します。管理者権限は不要です。

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup-client.ps1
```

セットアップ後は、デスクトップまたはスタートメニューの**Liaison Client**から起動できます。接続先やトークンを毎回入力する必要はありません。

## リポジトリから直接セットアップ

配布ZIPを作らず、ソースから直接セットアップすることもできます。この場合だけRustとNode.jsが必要です。

Server:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup-server.ps1
```

Client:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup-client.ps1 -ConnectionFile .\liaison-client.json
```

## Server版の前提条件

本番の`wsl-docker`モードでは以下が必要です。

- Windows 11 Pro
- WSL 2ディストリビューション
- WSL内で利用可能なDocker
- GPUを使う場合はNVIDIAドライバーとWSL GPU対応
- 別PCから操作する場合はServer・Client両方のTailscale

テスト用にDockerを使用しない場合:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup-server.ps1 -Runtime mock -LocalOnly
```

## 開発とテスト

```powershell
npm --prefix apps/liaison-desktop install
npm --prefix apps/liaison-desktop run build
cargo test --workspace
powershell -ExecutionPolicy Bypass -File .\scripts\smoke-test.ps1
```

安全なGUIデモ:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-demo.ps1
```

## 構成

- Rustの常駐サーバー
- Tauri 2 + ReactのWindowsクライアント
- ループバック限定のサーバープロセス
- Tailscale IPからループバックへ限定転送
- 16文字以上のトークン認証
- WSL Dockerランタイムと安全なMockランタイム
- CPU・RAM・GPUと最大Worker数の自動検出

詳細は`docs/ARCHITECTURE.md`と`docs/TESTING.md`を参照してください。
