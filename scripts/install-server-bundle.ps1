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

function Test-LiaisonPackageNoise([string]$Line) {
    if (-not $Line) { return $false }
    return $Line -match '^(Get:|Hit:|Ign:|Reading package lists|Building dependency tree|Reading state information|Selecting previously|Preparing to unpack|Unpacking |Setting up |Processing triggers|Created symlink|update-alternatives:|Fetched |The following |Suggested packages:|Need to get |After this operation,|\(Reading database|\d+ upgraded,|\d+ added,|\d+ removed;)'
}

$script:PackageProgressPublished = $false
$script:DockerProgressPublished = $false
$script:PublishedLiaisonLines = New-Object 'System.Collections.Generic.HashSet[string]'

function Publish-LiaisonLiveLine([string]$Source, [string]$Line) {
    $clean = (($Line -replace "\x00", "").Trim())
    if (-not $clean -or (Test-LiaisonTranscriptNoise $clean)) { return }

    if ($clean -match "apt-get update|^Get:|^Hit:|^Fetched ") {
        if (-not $script:PackageProgressPublished) {
            Write-LiaisonProgress 48 "Ubuntu packages" "Downloading packages required by Docker."
            $script:PackageProgressPublished = $true
        }
    } elseif ($clean -match "docker.io|docker-ce|dockerd") {
        if (-not $script:DockerProgressPublished) {
            Write-LiaisonProgress 52 "Docker startup" "Configuring Docker Engine and checking that it starts."
            $script:DockerProgressPublished = $true
        }
    }

    # The redirected stdout/stderr files remain available while setup is running. The
    # unified UI log intentionally omits package-manager chatter and duplicate lines.
    if ((Test-LiaisonPackageNoise $clean) -and $clean -notmatch '(^E:|error|failed|warning)') { return }
    if (-not $script:PublishedLiaisonLines.Add($clean)) { return }

    Write-LiaisonUnifiedLog ("DETAIL|" + $Source + "|" + $clean)

    if ($clean -match "Enabling Windows feature") {
        Write-LiaisonProgress 20 "WSL feature enable" "Preparing Windows virtualization features. A restart may be required."
    } elseif ($clean -match "Installing the .* WSL distribution") {
        Write-LiaisonProgress 26 "Ubuntu setup" "Preparing the Linux environment for the Liaison server."
    } elseif ($clean -match "Installing Docker Engine") {
        Write-LiaisonProgress 44 "Docker install" "Installing Docker Engine inside Ubuntu for worker execution."
    } elseif ($clean -match "Connecting the Tailscale") {
        Write-LiaisonProgress 58 "Tailscale connection" "Preparing secure access from other computers."
    } elseif ($clean -match "Liaison Server setup completed|Server installation completed") {
        Write-LiaisonProgress 78 "Liaison service" "Registering the Liaison service for automatic operation."
    } elseif ($clean -match "startup|Scheduled Task|repair") {
        Write-LiaisonProgress 82 "Windows startup" "Configuring Liaison to start automatically with Windows."
    }
}

Remove-Item -LiteralPath $InstallLog -Force -ErrorAction SilentlyContinue
$sessionId = [Guid]::NewGuid().ToString("N")
$stdoutLog = Join-Path $env:TEMP ("LiaisonServerCore-{0}.stdout.log" -f $sessionId)
$stderrLog = Join-Path $env:TEMP ("LiaisonServerCore-{0}.stderr.log" -f $sessionId)
$resultLog = Join-Path $env:TEMP ("LiaisonServerCore-{0}.exit.txt" -f $sessionId)
$commandFile = Join-Path $env:TEMP ("LiaisonServerCore-{0}.cmd" -f $sessionId)
Remove-Item -LiteralPath $stdoutLog, $stderrLog, $resultLog, $commandFile -Force -ErrorAction SilentlyContinue

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

# Windows PowerShell 5.1 can expose a null Process.ExitCode after redirected output.
# cmd.exe records the actual native ERRORLEVEL in a separate file before it exits.
$commandLines = @(
    "@echo off",
    ("powershell.exe " + $argumentLine),
    'set "liaison_exit=%ERRORLEVEL%"',
    ('> ' + (Quote-LiaisonArgument $resultLog) + ' echo %liaison_exit%'),
    'exit /b %liaison_exit%'
)
Set-Content -LiteralPath $commandFile -Value $commandLines -Encoding ASCII

Write-LiaisonProgress 16 "Server setup" "Preparing WSL, Ubuntu, Docker, Tailscale, and the Liaison service."
$commandArgumentLine = "/d /c " + (Quote-LiaisonArgument $commandFile)
$process = Start-Process -FilePath $env:ComSpec -WindowStyle Hidden -PassThru -ArgumentList $commandArgumentLine -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
$stdoutCount = 0
$stderrCount = 0

while (-not $process.HasExited) {
    if (Test-Path -LiteralPath $stdoutLog) {
        $lines = @(Get-Content -LiteralPath $stdoutLog -ErrorAction SilentlyContinue)
        for ($index = $stdoutCount; $index -lt $lines.Count; $index++) {
            Publish-LiaisonLiveLine "core" ([string]$lines[$index])
        }
        $stdoutCount = $lines.Count
    }
    if (Test-Path -LiteralPath $stderrLog) {
        $lines = @(Get-Content -LiteralPath $stderrLog -ErrorAction SilentlyContinue)
        for ($index = $stderrCount; $index -lt $lines.Count; $index++) {
            Publish-LiaisonLiveLine "error" ([string]$lines[$index])
        }
        $stderrCount = $lines.Count
    }
    Start-Sleep -Milliseconds 500
    $process.Refresh()
}

$process.WaitForExit()
$process.Refresh()

$finalSources = @(
    @{ Name = "core"; Path = $stdoutLog; Count = $stdoutCount },
    @{ Name = "error"; Path = $stderrLog; Count = $stderrCount }
)
foreach ($source in $finalSources) {
    if (Test-Path -LiteralPath $source.Path) {
        $lines = @(Get-Content -LiteralPath $source.Path -ErrorAction SilentlyContinue)
        for ($index = [int]$source.Count; $index -lt $lines.Count; $index++) {
            Publish-LiaisonLiveLine ([string]$source.Name) ([string]$lines[$index])
        }
    }
}

$processExitCode = -1
for ($attempt = 0; $attempt -lt 30 -and -not (Test-Path -LiteralPath $resultLog -PathType Leaf); $attempt++) {
    Start-Sleep -Milliseconds 100
}
if (Test-Path -LiteralPath $resultLog -PathType Leaf) {
    $recordedExitCode = ((Get-Content -LiteralPath $resultLog -Raw -ErrorAction SilentlyContinue) -as [string]).Trim()
    if ($recordedExitCode -match '^-?\d+$') {
        $processExitCode = [int]$recordedExitCode
        Write-LiaisonUnifiedLog ("Server core recorded exit code: " + $processExitCode)
    }
}
if ($processExitCode -eq -1) {
    try {
        if ($null -ne $process.ExitCode) {
            $processExitCode = [int]$process.ExitCode
            Write-LiaisonUnifiedLog ("WARNING|Result file was unavailable; process exit code fallback: " + $processExitCode)
        }
    } catch {
        Write-LiaisonUnifiedLog ("WARNING|Could not read server core result: " + $_.Exception.Message)
    }
}

Remove-Item -LiteralPath $commandFile, $resultLog, $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue
Write-LiaisonUnifiedLog ("Server core exit code: " + $processExitCode)
if ($processExitCode -eq 0) {
    Write-LiaisonProgress 86 "Server ready" "WSL, Docker, and the Liaison service are ready."
} else {
    Write-LiaisonUnifiedLog ("Installation failed: Server core exited with code " + $processExitCode + ".")
}

exit $processExitCode
