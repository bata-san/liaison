param(
    [string]$WslDistribution = "Ubuntu",
    [ValidateRange(1024, 65535)]
    [int]$Port = 57841,
    [string]$InstallDirectory = "$env:ProgramFiles\Liaison Server",
    [string]$ConfigDirectory = "$env:ProgramData\Liaison",
    [string]$TaskName = "LiaisonServer",
    [switch]$SkipRestart
)

$ErrorActionPreference = "Stop"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    throw "Run this repair from an elevated PowerShell session."
}

$ServerExe = Join-Path $InstallDirectory "liaison-service.exe"
$CliExe = Join-Path $InstallDirectory "liaison-cli.exe"
$ConfigPath = Join-Path $ConfigDirectory "liaison.json"
$HostScript = Join-Path $InstallDirectory "start-server.ps1"
$LogDirectory = Join-Path $ConfigDirectory "logs"
$HostLog = Join-Path $LogDirectory "host.log"
$StdoutLog = Join-Path $LogDirectory "server.log"
$StderrLog = Join-Path $LogDirectory "server-error.log"

foreach ($path in @($ServerExe, $CliExe, $ConfigPath)) {
    if (-not (Test-Path $path)) {
        throw "Required server file is missing: $path"
    }
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$token = [string]$config.auth_token
if ($token.Length -lt 16) {
    throw "The server token in $ConfigPath is invalid."
}
if ($config.wsl_distribution) {
    $WslDistribution = [string]$config.wsl_distribution
}
if ($config.listen_address -match ':(\d+)$') {
    $Port = [int]$Matches[1]
}

New-Item -ItemType Directory -Force -Path $InstallDirectory, $LogDirectory | Out-Null

$HostContent = @"
`$ErrorActionPreference = "Stop"
`$ServerExe = "$ServerExe"
`$CliExe = "$CliExe"
`$ConfigPath = "$ConfigPath"
`$WslDistribution = "$WslDistribution"
`$Port = $Port
`$Token = "$token"
`$LogDirectory = "$LogDirectory"
`$HostLog = "$HostLog"
`$StdoutLog = "$StdoutLog"
`$StderrLog = "$StderrLog"

New-Item -ItemType Directory -Force -Path `$LogDirectory | Out-Null

function Write-LiaisonHostLog([string]`$Message) {
    `$line = "{0} {1}" -f ([DateTimeOffset]::Now.ToString("o")), `$Message
    Add-Content -Path `$HostLog -Value `$line -Encoding UTF8
}

`$dockerStart = @'
set -eu
if docker info >/dev/null 2>&1; then exit 0; fi
if command -v service >/dev/null 2>&1; then service docker start >/dev/null 2>&1 || true; fi
if ! docker info >/dev/null 2>&1; then
  mkdir -p /var/log
  nohup dockerd > /var/log/liaison-dockerd.log 2>&1 &
fi
for i in `$(seq 1 120); do docker info >/dev/null 2>&1 && exit 0; sleep 1; done
exit 1
'@

try {
    Write-LiaisonHostLog "Starting Docker Engine in WSL distribution '`$WslDistribution'."
    & wsl.exe -d `$WslDistribution -u root -- sh -lc `$dockerStart >> `$HostLog 2>&1
    if (`$LASTEXITCODE -ne 0) {
        throw "Docker Engine did not become ready in WSL."
    }

    Remove-Item `$StdoutLog, `$StderrLog -Force -ErrorAction SilentlyContinue
    `$arguments = "--console --config ```"`$ConfigPath```""
    Write-LiaisonHostLog "Starting Liaison Server."
    `$process = Start-Process -FilePath `$ServerExe -ArgumentList `$arguments -PassThru -RedirectStandardOutput `$StdoutLog -RedirectStandardError `$StderrLog

    `$ready = `$false
    for (`$attempt = 0; `$attempt -lt 240; `$attempt++) {
        Start-Sleep -Milliseconds 500
        if (`$process.HasExited) { break }
        & `$CliExe --address "127.0.0.1:`$Port" --token `$Token health *> `$null
        if (`$LASTEXITCODE -eq 0) {
            `$ready = `$true
            break
        }
    }
    if (-not `$ready) {
        if (-not `$process.HasExited) {
            Stop-Process -Id `$process.Id -Force -ErrorAction SilentlyContinue
        }
        throw "Liaison Server did not become ready. See `$StderrLog and `$HostLog."
    }

    Write-LiaisonHostLog "Liaison Server is accepting connections."
    foreach (`$slot in @("P1", "P2")) {
        & `$CliExe --address "127.0.0.1:`$Port" --token `$Token start `$slot >> `$HostLog 2>&1
        if (`$LASTEXITCODE -eq 0) {
            Write-LiaisonHostLog "Persistent slot `$slot started."
        } else {
            Write-LiaisonHostLog "Persistent slot `$slot failed to start. The server remains online."
        }
    }

    `$process.WaitForExit()
    `$exitCode = `$process.ExitCode
    Write-LiaisonHostLog "Liaison Server exited with code `$exitCode."
    if (`$exitCode -ne 0) {
        throw "Liaison Server exited unexpectedly with code `$exitCode."
    }
} catch {
    Write-LiaisonHostLog ("Startup failure: " + `$_.Exception.Message)
    exit 1
} finally {
    `$dockerStop = 'ids=`$(docker ps -aq --filter label=liaison.slot 2>/dev/null || true); if [ -n "`$ids" ]; then docker stop -t 20 `$ids >/dev/null 2>&1 || true; fi'
    & wsl.exe -d `$WslDistribution -u root -- sh -lc `$dockerStop >> `$HostLog 2>&1
}
"@

[IO.File]::WriteAllText($HostScript, $HostContent, [Text.UTF8Encoding]::new($false))

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) {
    throw "Scheduled task '$TaskName' was not found. Run Install Liaison Server.cmd first."
}

if (-not $SkipRestart) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Get-Process -Name "liaison-service" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName $TaskName

    $ready = $false
    for ($attempt = 0; $attempt -lt 240; $attempt++) {
        Start-Sleep -Milliseconds 500
        & $CliExe --address "127.0.0.1:$Port" --token $token health *> $null
        if ($LASTEXITCODE -eq 0) {
            $ready = $true
            break
        }
        $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($taskInfo -and $taskInfo.LastTaskResult -ne 0 -and $attempt -gt 4) {
            break
        }
    }
    if (-not $ready) {
        $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        $result = if ($taskInfo) { $taskInfo.LastTaskResult } else { "unknown" }
        throw "The server did not start. Scheduled task result: $result. Logs: $StderrLog and $HostLog"
    }
}

Write-Host "Windows server startup repair completed." -ForegroundColor Green
Write-Host "Server log: $StdoutLog"
Write-Host "Error log:  $StderrLog"
Write-Host "Host log:   $HostLog"
