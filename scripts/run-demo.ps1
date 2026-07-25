param(
    [switch]$NoBuild,
    [switch]$NoGui
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$DemoDir = Join-Path $Root "runtime-data\demo"
$Config = Join-Path $DemoDir "liaison.demo.json"
$Token = "liaison-demo-token-2026"
New-Item -ItemType Directory -Force -Path $DemoDir | Out-Null

@{
    listen_address = "127.0.0.1:57841"
    auth_token = $Token
    runtime = "mock"
    wsl_distribution = "LiaisonRuntime"
    workspace_image = "ubuntu:24.04"
    persistent_image = "ubuntu:24.04"
    data_directory = $DemoDir
    persistent_pool = @{ cpu_threads = 6; memory_mib = 8192 }
    workspace_pool = @{ cpu_threads = 38; memory_mib = 40960 }
    class_workspace_pool = @{ cpu_threads = 12; memory_mib = 16384 }
    max_workspace_slots = 5
    persistent_autostart = $true
    metrics_interval_ms = 1000
} | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $Config

Push-Location $Root
try {
    if (-not $NoBuild) {
        cargo build -p liaison-service -p liaison-cli
        if ($LASTEXITCODE -ne 0) { throw "Rust build failed" }
    }

    $ServiceExe = Join-Path $Root "target\debug\liaison-service.exe"
    if (-not (Test-Path $ServiceExe)) { throw "Service executable not found: $ServiceExe" }

    $Service = Start-Process -FilePath $ServiceExe -ArgumentList @("--console", "--config", $Config, "--runtime", "mock") -PassThru -WindowStyle Hidden
    try {
        $env:LIAISON_ADDRESS = "127.0.0.1:57841"
        $env:LIAISON_TOKEN = $Token
        $Ready = $false
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 250
            & (Join-Path $Root "target\debug\liaison-cli.exe") health *> $null
            if ($LASTEXITCODE -eq 0) { $Ready = $true; break }
        }
        if (-not $Ready) { throw "Demo service did not become ready" }

        & (Join-Path $Root "target\debug\liaison-cli.exe") rebalance 3 | Out-Null
        Write-Host "Liaison demo service is running." -ForegroundColor Green
        Write-Host "Address: $env:LIAISON_ADDRESS"
        Write-Host "Runtime: mock (safe; WSL and Docker are not touched)"

        if ($NoGui) {
            & (Join-Path $Root "target\debug\liaison-cli.exe") snapshot
        } else {
            Push-Location (Join-Path $Root "apps\liaison-desktop")
            try {
                if (-not (Test-Path "node_modules")) { npm install }
                npm run tauri:dev
            } finally {
                Pop-Location
            }
        }
    } finally {
        if ($Service -and -not $Service.HasExited) { Stop-Process -Id $Service.Id -Force }
    }
} finally {
    Pop-Location
}
