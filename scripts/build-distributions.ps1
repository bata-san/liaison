param(
    [string]$OutputDirectory,
    [switch]$SkipTests,
    [switch]$SkipBuild
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
        throw "$Name was not found. $InstallHint"
    }
}

Require-Command "cargo.exe" "Install Rust from https://rustup.rs"
Require-Command "npm.cmd" "Install Node.js 22 or newer."

Push-Location $Root
try {
    if (-not $SkipBuild) {
        Write-Step "Building the frontend"
        npm --prefix apps/liaison-desktop install
        if ($LASTEXITCODE -ne 0) { throw "npm install failed." }
        npm --prefix apps/liaison-desktop run build
        if ($LASTEXITCODE -ne 0) { throw "The frontend build failed." }
    }

    if (-not $SkipTests) {
        Write-Step "Running tests"
        cargo test --workspace
        if ($LASTEXITCODE -ne 0) { throw "Rust tests failed." }
    }

    if (-not $SkipBuild) {
        Write-Step "Building release binaries"
        cargo build --release -p liaison-service -p liaison-cli -p liaison-desktop
        if ($LASTEXITCODE -ne 0) { throw "The release build failed." }
    }

    $RequiredBinaries = @(
        "target\release\liaison-service.exe",
        "target\release\liaison-cli.exe",
        "target\release\liaison-desktop.exe"
    )
    foreach ($binary in $RequiredBinaries) {
        if (-not (Test-Path $binary)) { throw "A release binary is missing: $binary" }
    }

    $ServerPackage = Join-Path $OutputDirectory "liaison-server-windows"
    $ClientPackage = Join-Path $OutputDirectory "liaison-client-windows"
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

    Write-Step "Creating the Windows server package"
    Copy-Item "target\release\liaison-service.exe" (Join-Path $ServerPackage "bin")
    Copy-Item "target\release\liaison-cli.exe" (Join-Path $ServerPackage "bin")
    Copy-Item "config\liaison.example.json" (Join-Path $ServerPackage "config")
    Copy-Item "scripts\setup-server.ps1" (Join-Path $ServerPackage "scripts")
    Copy-Item "scripts\install-server-bundle.ps1" (Join-Path $ServerPackage "scripts")
    Copy-Item "scripts\bootstrap-dependencies.ps1" (Join-Path $ServerPackage "scripts")
    @'
@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%CD%\scripts\install-server-bundle.ps1""'"
if errorlevel 1 pause
'@ | Set-Content -Path (Join-Path $ServerPackage "Install Liaison Server.cmd") -Encoding ASCII
    @'
Liaison Server for Windows

1. Extract this ZIP.
2. Double-click Install Liaison Server.cmd.
3. Restart Windows only when WSL is enabled for the first time.
4. Complete the one-time Tailscale browser login when prompted.
5. Copy the displayed liaison:// pairing code into Liaison Client.

Docker runs headlessly inside WSL. Docker Desktop is not required.
Tailscale is installed silently and runs as a background service.
The server stops Liaison-managed containers when it shuts down.
'@ | Set-Content -Path (Join-Path $ServerPackage "README.txt") -Encoding ASCII

    Write-Step "Creating the Windows client package"
    Copy-Item "target\release\liaison-desktop.exe" (Join-Path $ClientPackage "bin")
    Copy-Item "target\release\liaison-cli.exe" (Join-Path $ClientPackage "bin")
    Copy-Item "scripts\setup-client.ps1" (Join-Path $ClientPackage "scripts")
    Copy-Item "scripts\start-client.ps1" (Join-Path $ClientPackage "scripts")
    Copy-Item "scripts\install-client-bundle.ps1" (Join-Path $ClientPackage "scripts")
    Copy-Item "scripts\bootstrap-dependencies.ps1" (Join-Path $ClientPackage "scripts")
    @'
@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install-client-bundle.ps1"
if errorlevel 1 pause
'@ | Set-Content -Path (Join-Path $ClientPackage "Install Liaison Client.cmd") -Encoding ASCII
    @'
Liaison Client for Windows

1. Extract this ZIP.
2. Double-click Install Liaison Client.cmd.
3. Complete the one-time Tailscale browser login when prompted.
4. Open Liaison Client and paste the server pairing code.

A liaison-client.json file is optional. The app saves connection settings itself.
Worker management and the workspace terminal are integrated into Liaison Client.
Tailscale runs as a background service without opening its GUI.
'@ | Set-Content -Path (Join-Path $ClientPackage "README.txt") -Encoding ASCII

    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    Compress-Archive -Path (Join-Path $ServerPackage "*") -DestinationPath $ServerZip -CompressionLevel Optimal
    Compress-Archive -Path (Join-Path $ClientPackage "*") -DestinationPath $ClientZip -CompressionLevel Optimal

    Write-Host "`nDistribution packages created." -ForegroundColor Green
    Write-Host "Server: $ServerZip"
    Write-Host "Client: $ClientZip"
} finally {
    Pop-Location
}
