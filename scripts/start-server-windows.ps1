param(
    [string]$TaskName = "LiaisonServer",
    [ValidateRange(10, 300)]
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = "Stop"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-TaskName", "`"$TaskName`"",
        "-TimeoutSeconds", $TimeoutSeconds
    )
    $process = Start-Process -FilePath "powershell.exe" -Verb RunAs -Wait -PassThru -ArgumentList $arguments
    exit $process.ExitCode
}

$InstallDirectory = "$env:ProgramFiles\Liaison Server"
$ConfigDirectory = "$env:ProgramData\Liaison"
$CliExe = Join-Path $InstallDirectory "liaison-cli.exe"
$ConfigPath = Join-Path $ConfigDirectory "liaison.json"
$LogDirectory = Join-Path $ConfigDirectory "logs"
$HostLog = Join-Path $LogDirectory "host.log"
$StderrLog = Join-Path $LogDirectory "server-error.log"

if (-not (Test-Path $CliExe) -or -not (Test-Path $ConfigPath)) {
    throw "Liaison Server is not installed. Run Install Liaison Server.cmd first."
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$token = [string]$config.auth_token
$address = [string]$config.listen_address
if (-not $address) {
    $address = "127.0.0.1:57841"
}

Write-Host "Starting Liaison Server..."
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Get-Process -Name "liaison-service" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName $TaskName

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
while ([DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 500
    & $CliExe --address $address --token $token health *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Liaison Server is running at $address" -ForegroundColor Green
        Write-Host "Host log:  $HostLog"
        Write-Host "Error log: $StderrLog"
        exit 0
    }

    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($info -and $info.LastTaskResult -ne 0) {
        break
    }
}

Write-Host "Liaison Server failed to start." -ForegroundColor Red
$taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
if ($taskInfo) {
    Write-Host "Scheduled task result: $($taskInfo.LastTaskResult)"
}
foreach ($path in @($StderrLog, $HostLog)) {
    Write-Host ""
    Write-Host "--- $path ---"
    if (Test-Path $path) {
        Get-Content $path -Tail 50
    } else {
        Write-Host "Log file was not created."
    }
}
exit 1
