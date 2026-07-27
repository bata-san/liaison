# Liaison

Liaisonは、別PCのCPU・RAM・GPUをPersistentスロットとWorkspaceスロットへ割り当て、同じクライアントから管理と作業を行う軽量なワークステーション基盤です。

## 配布構成

- **Server版**: 管理対象PCへ入れます。コンテナ、リソース割り当て、接続認証を管理します。
- **Client版**: 操作用PCへ入れます。設定画面、Worker管理、Workspaceターミナルを1つのアプリで提供します。

対応配布物:

- Windows Server / Client
- AppleシリコンMac Server / Client

配布ZIPには実行ファイルが含まれるため、セットアップ先PCにRustやNode.jsは不要です。

## 最短セットアップ

### 1. Server版

Server ZIPを展開し、OSに合うインストーラーを実行します。

Windows:

```text
Install Liaison Server.cmd
```

AppleシリコンMac:

```text
Install Liaison Server.command
```

セットアップが行うこと:

- マシンスペック検出とリソース自動調整
- 強いランダムトークンの生成
- ログイン時の自動起動登録
- ヘッドレスなDockerランタイムの導入と起動
- ヘッドレスなTailscale接続の準備
- サーバー疎通確認
- `liaison://connect?...`形式のペアリングコード生成

WindowsではDocker EngineをWSL内で動かします。Docker Desktopは不要です。

MacではColimaとDocker CLIを使います。Docker Desktopは不要です。TailscaleはGUI版ではなくCLI-onlyデーモンを使います。

### 2. Client版

Client ZIPを展開し、OSに合うインストーラーを実行します。

Windows:

```text
Install Liaison Client.cmd
```

AppleシリコンMac:

```text
Install Liaison Client.command
```

初回起動後、Serverセットアップで表示されたペアリングコードを貼り付けます。`liaison-client.json`のコピーは任意です。

接続後は同じアプリから以下を操作できます。

- 運用モード
- Persistent / Workspace割り当て
- CPU・RAM・GPU設定
- Workerの起動・停止
- Worker内のWorkspaceターミナル
- コマンド出力と実行履歴

## コンテナの安定化

Docker実体とLiaison設定の不一致を減らすため、次を行います。

- CPU上限、メモリ上限、メモリスワップ上限を同時更新
- 更新後にDockerの実際の上限を再確認
- 更新に失敗した場合は名前付きボリュームを保持してコンテナ本体だけ再作成
- Liaison Server終了時に管理対象コンテナを停止
- 制御要求を接続ごとに処理し、長いコンテナ操作が他の接続を塞ぎにくい構成

## 接続方法

Serverは制御ポートをループバックに限定し、Tailscale経由で別PCへ公開します。ClientはIP・ポート・トークンをOS標準の設定場所へ保存します。

接続できない場合はアプリ内で以下を編集できます。

- ペアリングコード
- Server IPまたはホスト名
- ポート
- 接続トークン

IPだけを入力した場合は既定ポート`57841`を使用します。

## 前提条件

Windows Server:

- Windows 11
- WSL 2
- Ubuntu系WSLディストリビューション
- GPU利用時はNVIDIAドライバーとWSL GPU対応

AppleシリコンMac Server:

- Appleシリコン
- macOS 13以降を推奨
- Apple GPUは通常のDocker Worker割り当てでは無効

別PCから接続する場合はServer・Client双方が同じTailscaleネットワークへログインしている必要があります。初回ログイン時だけブラウザが開くことがありますが、通常運用でDockerやTailscaleのGUIを開く必要はありません。

## 開発とテスト

Windows配布物:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-distributions.ps1
```

AppleシリコンMac配布物:

```bash
./scripts/build-macos-distributions.sh
```

共通テスト:

```text
npm --prefix apps/liaison-desktop install
npm --prefix apps/liaison-desktop run build
cargo test --workspace
```

Mock E2E:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\smoke-test.ps1
```

## 制限

- 実際のWSL、Colima、Docker、Tailscale、GPUを使う最終確認は対象PC上で必要です。
- Macの通常Docker WorkerへApple GPUを直接割り当てる機能はありません。
- Workspaceターミナルは認証済みWorkerコンテナ内でコマンドを実行する機能で、現段階では完全なIDEやファイル同期クライアントではありません。
- macOS配布物はDeveloper ID公証版ではなくローカル用署名です。

詳細は`docs/ARCHITECTURE.md`と`docs/TESTING.md`を参照してください。
