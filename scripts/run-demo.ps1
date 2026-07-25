param(
    [switch]$NoBuild,
    [switch]$NoGui
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$DemoDir = Join-Path $Root "runtime-data\demo"
$Config = Join-Path $DemoDir "liaison.demo.json"
$Token = "liaison-demo-token-2026"
$ServiceExe = Join-Path $Root "target\debug\liaison-service.exe"
$CliExe = Join-Path $Root "target\debug\liaison-cli.exe"

function Stop-StaleDemoService {
    param([string]$ExpectedPath)

    $expectedFullPath = [System.IO.Path]::GetFullPath($ExpectedPath)
    $staleProcesses = Get-Process -Name "liaison-service" -ErrorAction SilentlyContinue
    foreach ($process in $staleProcesses) {
        $processPath = $null
        try {
            $processPath = $process.Path
        } catch {
            # A process owned by another account may not expose its path.
        }

        if ($processPath -and ([System.IO.Path]::GetFullPath($processPath) -ieq $expectedFullPath)) {
            Write-Host "Stopping stale Liaison demo service (PID $($process.Id))..." -ForegroundColor Yellow
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $process.Id -Timeout 5 -ErrorAction SilentlyContinue
        }
    }
}

New-Item -ItemType Directory -Force -Path $DemoDir | Out-Null

$ConfigJson = @{
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
} | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($Config, $ConfigJson, [System.Text.UTF8Encoding]::new($false))

Push-Location $Root
try {
    # Windows locks a running .exe. A previous interrupted demo can therefore
    # prevent Cargo from replacing target\debug\liaison-service.exe.
    Stop-StaleDemoService -ExpectedPath $ServiceExe

    if (-not $NoBuild) {
        cargo build -p liaison-service -p liaison-cli
        if ($LASTEXITCODE -ne 0) { throw "Rust build failed" }
    }

    if (-not (Test-Path $ServiceExe)) { throw "Service executable not found: $ServiceExe" }
    if (-not (Test-Path $CliExe)) { throw "CLI executable not found: $CliExe" }

    $Service = Start-Process -FilePath $ServiceExe -ArgumentList @("--console", "--config", $Config, "--runtime", "mock") -PassThru -WindowStyle Hidden
    try {
        $env:LIAISON_ADDRESS = "127.0.0.1:57841"
        $env:LIAISON_TOKEN = $Token
        $Ready = $false
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 250
            & $CliExe health *> $null
            if ($LASTEXITCODE -eq 0) { $Ready = $true; break }
        }
        if (-not $Ready) { throw "Demo service did not become ready" }

        & $CliExe rebalance 3 | Out-Null
        foreach ($slot in @("W1", "W2", "W3")) {
            & $CliExe gpu $slot shared | Out-Null
        }

        Write-Host "Liaison demo service is running." -ForegroundColor Green
        Write-Host "Address: $env:LIAISON_ADDRESS"
        Write-Host "Runtime: mock (safe; WSL and Docker are not touched)"

        if ($NoGui) {
            & $CliExe snapshot
        } else {
            Push-Location (Join-Path $Root "apps\liaison-desktop")
            try {
                # Always reconcile dependencies. This is fast when node_modules is current
                # and ensures newly added UI packages are installed on existing checkouts.
                npm install --no-audit --no-fund
                if ($LASTEXITCODE -ne 0) { throw "Frontend dependency installation failed" }

                npm run tauri:dev
                if ($LASTEXITCODE -ne 0) { throw "Tauri development host failed" }
            } finally {
                Pop-Location
            }
        }
    } finally {
        if ($Service -and -not $Service.HasExited) {
            Stop-Process -Id $Service.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $Service.Id -Timeout 5 -ErrorAction SilentlyContinue
        }
    }
} finally {
    Pop-Location
}
