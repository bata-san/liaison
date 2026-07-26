param(
    [string]$OutputDirectory,
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $Root "dist"
}

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Require-Command([string]$Name, [string]$InstallHint) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name が見つかりません。$InstallHint"
    }
}

Require-Command "cargo.exe" "Rustをインストールしてください: https://rustup.rs"
Require-Command "npm.cmd" "Node.js 22以降をインストールしてください。"

Push-Location $Root
try {
    Write-Step "フロントエンドをビルド"
    npm --prefix apps/liaison-desktop install
    if ($LASTEXITCODE -ne 0) {
        throw "npm installに失敗しました。"
    }
    npm --prefix apps/liaison-desktop run build
    if ($LASTEXITCODE -ne 0) {
        throw "フロントエンドのビルドに失敗しました。"
    }

    if (-not $SkipTests) {
        Write-Step "テストを実行"
        cargo test --workspace
        if ($LASTEXITCODE -ne 0) {
            throw "Rustテストに失敗しました。"
        }
    }

    Write-Step "Releaseバイナリをビルド"
    cargo build --release -p liaison-service -p liaison-cli -p liaison-desktop
    if ($LASTEXITCODE -ne 0) {
        throw "Releaseビルドに失敗しました。"
    }

    $ServerPackage = Join-Path $OutputDirectory "liaison-server"
    $ClientPackage = Join-Path $OutputDirectory "liaison-client"
    $ServerZip = Join-Path $OutputDirectory "liaison-server-windows.zip"
    $ClientZip = Join-Path $OutputDirectory "liaison-client-windows.zip"

    Remove-Item $ServerPackage, $ClientPackage -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $ServerZip, $ClientZip -Force -ErrorAction SilentlyContinue

    New-Item -ItemType Directory -Force -Path `
        (Join-Path $ServerPackage "bin"), `
        (Join-Path $ServerPackage "scripts"), `
        (Join-Path $ServerPackage "config"), `
        (Join-Path $ClientPackage "bin"), `
        (Join-Path $ClientPackage "scripts") | Out-Null

    Write-Step "サーバー版を作成"
    Copy-Item "target\release\liaison-service.exe" (Join-Path $ServerPackage "bin")
    Copy-Item "target\release\liaison-cli.exe" (Join-Path $ServerPackage "bin")
    Copy-Item "scripts\setup-server.ps1" (Join-Path $ServerPackage "scripts")
    Copy-Item "config\liaison.example.json" (Join-Path $ServerPackage "config")
    @'
Liaison Server

1. このZIPをサーバーPCで展開します。
2. 管理者PowerShellで展開先を開きます。
3. 次を実行します。

   powershell -ExecutionPolicy Bypass -File .\scripts\setup-server.ps1

完了するとデスクトップに liaison-client.json が作成されます。
そのJSONをクライアント版フォルダーへコピーしてください。
'@ | Set-Content -Path (Join-Path $ServerPackage "README.txt") -Encoding UTF8

    Write-Step "クライアント版を作成"
    Copy-Item "target\release\liaison-desktop.exe" (Join-Path $ClientPackage "bin")
    Copy-Item "target\release\liaison-cli.exe" (Join-Path $ClientPackage "bin")
    Copy-Item "scripts\setup-client.ps1" (Join-Path $ClientPackage "scripts")
    Copy-Item "scripts\start-client.ps1" (Join-Path $ClientPackage "scripts")
    @'
Liaison Client

1. このZIPをクライアントPCで展開します。
2. サーバーで作成された liaison-client.json を、このフォルダー直下へコピーします。
3. PowerShellで次を実行します。管理者権限は不要です。

   powershell -ExecutionPolicy Bypass -File .\scripts\setup-client.ps1

完了後はデスクトップまたはスタートメニューの「Liaison Client」から起動できます。
'@ | Set-Content -Path (Join-Path $ClientPackage "README.txt") -Encoding UTF8

    Compress-Archive -Path (Join-Path $ServerPackage "*") -DestinationPath $ServerZip -CompressionLevel Optimal
    Compress-Archive -Path (Join-Path $ClientPackage "*") -DestinationPath $ClientZip -CompressionLevel Optimal

    Write-Host "`n配布パッケージを作成しました" -ForegroundColor Green
    Write-Host "サーバー版: $ServerZip"
    Write-Host "クライアント版: $ClientZip"
} finally {
    Pop-Location
}
