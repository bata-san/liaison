param(
    [string]$WslDistribution = "Ubuntu",
    [switch]$LocalOnly,
    [switch]$SkipDependencyInstall,
    [string]$LauncherLogPath,
    [string]$InstallLogPath
)

$ErrorActionPreference = "Stop"
$LauncherLog = if ($LauncherLogPath) { $LauncherLogPath } else { Join-Path $env:TEMP "LiaisonServerLauncher.log" }
$InstallLog = if ($InstallLogPath) { $InstallLogPath } else { Join-Path $env:TEMP "LiaisonServerInstall.log" }
$env:LIAISON_UNIFIED_LOG_PATH = $LauncherLog
$env:LIAISON_SETUP_ROLE = "server"

$progressHelper = Join-Path $PSScriptRoot "setup-progress.ps1"
if (-not (Test-Path -LiteralPath $progressHelper -PathType Leaf)) {
    throw ("Setup progress helper is missing: " + $progressHelper)
}
. $progressHelper

$coreInstaller = Join-Path $PSScriptRoot "install-server-core.ps1"
if (-not (Test-Path -LiteralPath $coreInstaller -PathType Leaf)) {
    throw ("Core server installer is missing: " + $coreInstaller)
}

function Quote-LiaisonArgument([string]$Value) {
    if ($null -eq $Value) { return '""' }
    if ($Value.Contains('"')) { throw "A setup argument contains an unsupported quote character." }
    return '"' + $Value + '"'
}

function Test-LiaisonTranscriptNoise([string]$Line) {
    if (-not $Line) { return $true }
    return $Line -match '^\*+$' -or
        $Line -match '^Windows PowerShell ' -or
        $Line -match '^(RunAs |PSVersion:|PSEdition:|PSCompatibleVersions:|BuildVersion:|CLRVersion:|WSManStackVersion:|PSRemotingProtocolVersion:|SerializationVersion:)'
}

function Publish-LiaisonLiveLine([string]$Source, [string]$Line) {
    $clean = (($Line -replace "\x00", "").Trim())
    if (-not $clean -or (Test-LiaisonTranscriptNoise $clean)) { return }
    Write-LiaisonUnifiedLog ("DETAIL|" + $Source + "|" + $clean)

    if ($clean -match "Enabling Windows feature") {
        Write-LiaisonProgress 20 "WSL feature enable" "Preparing Windows virtualization features. A restart may be required."
    } elseif ($clean -match "Installing the .* WSL distribution") {
        Write-LiaisonProgress 26 "Ubuntu setup" "Preparing the Linux environment for the Liaison server."
    } elseif ($clean -match "Installing Docker Engine") {
        Write-LiaisonProgress 44 "Docker install" "Installing Docker Engine inside Ubuntu for worker execution."
    } elseif ($clean -match "apt-get update|Get:|Fetched") {
        Write-LiaisonProgress 48 "Ubuntu packages" "Downloading packages required by Docker."
    } elseif ($clean -match "docker.io|docker-ce|dockerd") {
        Write-LiaisonProgress 52 "Docker startup" "Configuring Docker Engine and checking that it starts."
    } elseif ($clean -match "Connecting the Tailscale") {
        Write-LiaisonProgress 58 "Tailscale connection" "Preparing secure access from other computers."
    } elseif ($clean -match "Liaison Server setup completed|Server installation completed") {
        Write-LiaisonProgress 78 "Liaison service" "Registering the Liaison service for automatic operation."
    } elseif ($clean -match "startup|Scheduled Task|repair") {
        Write-LiaisonProgress 82 "Windows startup" "Configuring Liaison to start automatically with Windows."
    }
}

Remove-Item -LiteralPath $InstallLog -Force -ErrorAction SilentlyContinue
$stdoutLog = Join-Path $env:TEMP "LiaisonServerCore.stdout.log"
$stderrLog = Join-Path $env:TEMP "LiaisonServerCore.stderr.log"
Remove-Item -LiteralPath $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue

$parts = @(
    "-NoLogo",
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", (Quote-LiaisonArgument $coreInstaller),
    "-WslDistribution", (Quote-LiaisonArgument $WslDistribution),
    "-LauncherLogPath", (Quote-LiaisonArgument $LauncherLog),
    "-InstallLogPath", (Quote-LiaisonArgument $InstallLog)
)
if ($LocalOnly) { $parts += "-LocalOnly" }
if ($SkipDependencyInstall) { $parts += "-SkipDependencyInstall" }
$argumentLine = $parts -join " "

Write-LiaisonProgress 16 "Server setup" "Preparing WSL, Ubuntu, Docker, Tailscale, and the Liaison service."
$process = Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -PassThru -ArgumentList $argumentLine -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
$installCount = 0
$stdoutCount = 0
$stderrCount = 0

while (-not $process.HasExited) {
    if (Test-Path -LiteralPath $InstallLog) {
        $lines = @(Get-Content -LiteralPath $InstallLog -ErrorAction SilentlyContinue)
        for ($index = $installCount; $index -lt $lines.Count; $index++) {
            Publish-LiaisonLiveLine "PowerShell" ([string]$lines[$index])
        }
        $installCount = $lines.Count
    }
    if (Test-Path -LiteralPath $stdoutLog) {
        $lines = @(Get-Content -LiteralPath $stdoutLog -ErrorAction SilentlyContinue)
        for ($index = $stdoutCount; $index -lt $lines.Count; $index++) {
            Publish-LiaisonLiveLine "stdout" ([string]$lines[$index])
        }
        $stdoutCount = $lines.Count
    }
    if (Test-Path -LiteralPath $stderrLog) {
        $lines = @(Get-Content -LiteralPath $stderrLog -ErrorAction SilentlyContinue)
        for ($index = $stderrCount; $index -lt $lines.Count; $index++) {
            Publish-LiaisonLiveLine "stderr" ([string]$lines[$index])
        }
        $stderrCount = $lines.Count
    }
    Start-Sleep -Milliseconds 700
    $process.Refresh()
}

# WaitForExit also flushes redirected stdout and stderr. A missing exit code is
# never success; use -1 so the parent installer cannot continue after failure.
$process.WaitForExit()
$process.Refresh()
$processExitCode = -1
try {
    if ($null -ne $process.ExitCode) {
        $processExitCode = [int]$process.ExitCode
    }
} catch {
    Write-LiaisonUnifiedLog ("WARNING|Could not read server core exit code: " + $_.Exception.Message)
}

$finalSources = @(
    @{ Name = "PowerShell"; Path = $InstallLog; Count = $installCount },
    @{ Name = "stdout"; Path = $stdoutLog; Count = $stdoutCount },
    @{ Name = "stderr"; Path = $stderrLog; Count = $stderrCount }
)
foreach ($source in $finalSources) {
    if (Test-Path -LiteralPath $source.Path) {
        $lines = @(Get-Content -LiteralPath $source.Path -ErrorAction SilentlyContinue)
        for ($index = [int]$source.Count; $index -lt $lines.Count; $index++) {
            Publish-LiaisonLiveLine ([string]$source.Name) ([string]$lines[$index])
        }
    }
}

Write-LiaisonUnifiedLog ("Server core exit code: " + $processExitCode)
if ($processExitCode -eq 0) {
    Write-LiaisonProgress 86 "Server ready" "WSL, Docker, and the Liaison service are ready."
} else {
    Write-LiaisonUnifiedLog ("Installation failed: Server core exited with code " + $processExitCode + ".")
}

exit $processExitCode
