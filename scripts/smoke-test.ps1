param(
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("liaison-smoke-" + [Guid]::NewGuid().ToString("N"))
$Config = Join-Path $TempRoot "liaison.json"
$Token = "liaison-smoke-token-2026"
New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null

$ConfigJson = @{
    listen_address = "127.0.0.1:57841"
    auth_token = $Token
    runtime = "mock"
    wsl_distribution = "LiaisonRuntime"
    workspace_image = "ubuntu:24.04"
    persistent_image = "ubuntu:24.04"
    data_directory = $TempRoot
    persistent_pool = @{ cpu_threads = 6; memory_mib = 8192 }
    workspace_pool = @{ cpu_threads = 38; memory_mib = 40960 }
    class_workspace_pool = @{ cpu_threads = 12; memory_mib = 16384 }
    max_workspace_slots = 5
    persistent_autostart = $true
    metrics_interval_ms = 250
} | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($Config, $ConfigJson, [System.Text.UTF8Encoding]::new($false))

Push-Location $Root
try {
    if (-not $SkipBuild) {
        cargo build -p liaison-service -p liaison-cli
        if ($LASTEXITCODE -ne 0) { throw "Rust build failed" }
    }

    $ServiceExe = Join-Path $Root "target\debug\liaison-service.exe"
    $CliExe = Join-Path $Root "target\debug\liaison-cli.exe"
    $Service = Start-Process -FilePath $ServiceExe -ArgumentList @("--console", "--config", $Config, "--runtime", "mock") -PassThru -WindowStyle Hidden
    try {
        $Common = @("--address", "127.0.0.1:57841", "--token", $Token)
        $Ready = $false
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Milliseconds 200
            & $CliExe @Common health *> $null
            if ($LASTEXITCODE -eq 0) { $Ready = $true; break }
        }
        if (-not $Ready) { throw "Service did not become ready" }

        $Health = (& $CliExe @Common health | Out-String | ConvertFrom-Json)
        if ($Health.service -ne "liaison-service") { throw "Health response was invalid" }

        & $CliExe @Common rebalance 5 | Out-Null
        $Snapshot = (& $CliExe @Common snapshot | Out-String | ConvertFrom-Json)
        $Running = @($Snapshot.slots | Where-Object { $_.kind -eq "workspace" -and $_.status -eq "running" })
        if ($Running.Count -ne 5) { throw "Expected five running workspace slots, got $($Running.Count)" }
        $WorkspacePool = $Snapshot.pools | Where-Object { $_.id -eq "workspace" }
        if ($WorkspacePool.cpu_allocated_threads -ne 38) { throw "Workspace CPU allocation was not preserved" }

        & $CliExe @Common gpu W1 exclusive | Out-Null
        $Snapshot = (& $CliExe @Common snapshot | Out-String | ConvertFrom-Json)
        if ($Snapshot.gpu.reserved_by -ne "W1") { throw "GPU reservation failed" }

        & $CliExe @Common mode class | Out-Null
        $Snapshot = (& $CliExe @Common snapshot | Out-String | ConvertFrom-Json)
        $Throttled = @($Snapshot.slots | Where-Object { $_.kind -eq "workspace" -and $_.status -eq "throttled" })
        if ($Throttled.Count -ne 5) { throw "Class mode did not throttle workspace slots" }

        & $CliExe @Common mode local-exclusive | Out-Null
        $Snapshot = (& $CliExe @Common snapshot | Out-String | ConvertFrom-Json)
        $ActiveWorkspace = @($Snapshot.slots | Where-Object { $_.kind -eq "workspace" -and $_.status -ne "stopped" })
        $ActivePersistent = @($Snapshot.slots | Where-Object { $_.kind -eq "persistent" -and $_.status -eq "running" })
        if ($ActiveWorkspace.Count -ne 0) { throw "Local-exclusive mode left workspace slots active" }
        if ($ActivePersistent.Count -ne 2) { throw "Local-exclusive mode stopped persistent slots" }

        Write-Host "Liaison smoke test passed." -ForegroundColor Green
    } finally {
        if ($Service -and -not $Service.HasExited) { Stop-Process -Id $Service.Id -Force }
    }
} finally {
    Pop-Location
    Remove-Item -Recurse -Force $TempRoot -ErrorAction SilentlyContinue
}
