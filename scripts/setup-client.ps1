param(
    [string]$ConnectionFile,
    [string]$InstallDirectory = "$env:LOCALAPPDATA\Programs\Liaison Client",
    [switch]$SkipBuild,
    [switch]$NoDesktopShortcut,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$PackagedBin = Join-Path $Root "bin"
$ClientConfigDirectory = Join-Path $env:APPDATA "Liaison"
$ClientConfigPath = Join-Path $ClientConfigDirectory "client.json"

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Require-Command([string]$Name, [string]$InstallHint) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name が見つかりません。$InstallHint"
    }
}

function Find-ConnectionFile([string]$RequestedPath) {
    $candidates = @()
    if ($RequestedPath) {
        $candidates += $RequestedPath
    }
    $candidates += @(
        (Join-Path $Root "liaison-client.json"),
        (Join-Path (Get-Location) "liaison-client.json"),
        (Join-Path $env:USERPROFILE "Desktop\liaison-client.json"),
        (Join-Path $env:USERPROFILE "Downloads\liaison-client.json")
    )

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if ($candidate -and (Test-Path $candidate)) {
            return (Resolve-Path $candidate).Path
        }
    }
    return $null
}

function New-Shortcut(
    [string]$ShortcutPath,
    [string]$LauncherPath,
    [string]$WorkingDirectory,
    [string]$IconPath
) {
    $directory = Split-Path -Parent $ShortcutPath
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$LauncherPath`""
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.IconLocation = "$IconPath,0"
    $shortcut.Description = "Liaison workstation client"
    $shortcut.Save()
}

Write-Step "接続ファイルを確認"
$ResolvedConnectionFile = Find-ConnectionFile $ConnectionFile
if (-not $ResolvedConnectionFile) {
    throw "liaison-client.jsonが見つかりません。サーバーPCでsetup-server.ps1を実行し、生成されたJSONをクライアント版フォルダーへコピーしてください。"
}

$Connection = Get-Content $ResolvedConnectionFile -Raw | ConvertFrom-Json
if (-not $Connection.address) {
    throw "接続ファイルにaddressがありません: $ResolvedConnectionFile"
}
if (-not $Connection.token -or ([string]$Connection.token).Length -lt 16) {
    throw "接続ファイルのtokenが無効です: $ResolvedConnectionFile"
}
Write-Host "接続先: $($Connection.address)" -ForegroundColor Green

Push-Location $Root
try {
    $PackagedClient = Join-Path $PackagedBin "liaison-desktop.exe"
    $PackagedCli = Join-Path $PackagedBin "liaison-cli.exe"
    $UsePackagedBinaries = (Test-Path $PackagedClient) -and (Test-Path $PackagedCli)

    if ($UsePackagedBinaries) {
        Write-Step "配布済みクライアントを使用"
        $SourceClient = $PackagedClient
        $SourceCli = $PackagedCli
    } else {
        Write-Step "クライアントをビルド"
        Require-Command "cargo.exe" "Rustをインストールしてください: https://rustup.rs"
        Require-Command "npm.cmd" "Node.js 22以降をインストールしてください。"
        if (-not $SkipBuild) {
            npm --prefix apps/liaison-desktop install
            if ($LASTEXITCODE -ne 0) {
                throw "フロントエンド依存関係のインストールに失敗しました。"
            }
            npm --prefix apps/liaison-desktop run build
            if ($LASTEXITCODE -ne 0) {
                throw "フロントエンドのビルドに失敗しました。"
            }
            cargo build --release -p liaison-desktop -p liaison-cli
            if ($LASTEXITCODE -ne 0) {
                throw "クライアントのReleaseビルドに失敗しました。"
            }
        }
        $SourceClient = Join-Path $Root "target\release\liaison-desktop.exe"
        $SourceCli = Join-Path $Root "target\release\liaison-cli.exe"
    }

    if (-not (Test-Path $SourceClient) -or -not (Test-Path $SourceCli)) {
        throw "クライアントバイナリがありません。配布ZIPを使うか、-SkipBuildを外して実行してください。"
    }

    Write-Step "クライアントをインストール"
    New-Item -ItemType Directory -Force -Path $InstallDirectory, $ClientConfigDirectory | Out-Null
    $ClientExe = Join-Path $InstallDirectory "liaison-desktop.exe"
    $CliExe = Join-Path $InstallDirectory "liaison-cli.exe"
    $LauncherPath = Join-Path $InstallDirectory "start-client.ps1"

    Get-Process -Name "liaison-desktop" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Copy-Item $SourceClient $ClientExe -Force
    Copy-Item $SourceCli $CliExe -Force
    Copy-Item (Join-Path $PSScriptRoot "start-client.ps1") $LauncherPath -Force

    $SavedConnection = [ordered]@{
        version = 1
        server_name = [string]$Connection.server_name
        address = [string]$Connection.address
        token = [string]$Connection.token
        transport = [string]$Connection.transport
        installed_at = [DateTimeOffset]::Now.ToString("o")
    }
    [IO.File]::WriteAllText(
        $ClientConfigPath,
        ($SavedConnection | ConvertTo-Json -Depth 5),
        [Text.UTF8Encoding]::new($false)
    )

    Write-Step "ショートカットを作成"
    $StartMenuShortcut = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Liaison Client.lnk"
    New-Shortcut $StartMenuShortcut $LauncherPath $InstallDirectory $ClientExe
    if (-not $NoDesktopShortcut) {
        $DesktopShortcut = Join-Path $env:USERPROFILE "Desktop\Liaison Client.lnk"
        New-Shortcut $DesktopShortcut $LauncherPath $InstallDirectory $ClientExe
    }

    Write-Step "サーバー接続を確認"
    & $CliExe --address ([string]$Connection.address) --token ([string]$Connection.token) health
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "インストールは完了しましたが、サーバーへ接続できません。サーバー、Tailscale、ファイアウォールを確認してください。"
    } else {
        Write-Host "接続: OK" -ForegroundColor Green
    }

    Write-Host "`nセットアップ完了" -ForegroundColor Green
    Write-Host "スタートメニューまたはデスクトップの『Liaison Client』から起動できます。"
    Write-Host "設定: $ClientConfigPath"

    if (-not $NoLaunch) {
        & $LauncherPath
    }
} finally {
    Pop-Location
}
