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

function Publish-LiaisonLiveLine([string]$Source, [string]$Line) {
    $clean = (($Line -replace "\x00", "").Trim())
    if (-not $clean) { return }
    Write-LiaisonUnifiedLog ("DETAIL|" + $Source + "|" + $clean)

    if ($clean -match "Enabling Windows feature") {
        Write-LiaisonProgress 20 "WSL機能を有効化" $clean
    } elseif ($clean -match "Installing the .* WSL distribution") {
        Write-LiaisonProgress 26 "Ubuntuを準備" $clean
    } elseif ($clean -match "Installing Docker Engine") {
        Write-LiaisonProgress 38 "Dockerをインストール" $clean
    } elseif ($clean -match "apt-get update|Get:|Fetched") {
        Write-LiaisonProgress 44 "Ubuntuパッケージを取得" $clean
    } elseif ($clean -match "docker.io|docker-ce|dockerd") {
        Write-LiaisonProgress 50 "Dockerを構成" $clean
    } elseif ($clean -match "Connecting the Tailscale") {
        Write-LiaisonProgress 58 "Tailscaleを接続" $clean
    } elseif ($clean -match "Liaison Server setup completed|Server installation completed") {
        Write-LiaisonProgress 78 "Liaison Serviceを導入" $clean
    } elseif ($clean -match "startup|Scheduled Task|repair") {
        Write-LiaisonProgress 82 "Windows自動起動を設定" $clean
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

Write-LiaisonProgress 16 "サーバー構成を開始" "WSL、Ubuntu、Docker、Tailscale、Liaison Serviceを順番に設定します。"
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

foreach ($source in @(
    @{ Name = "PowerShell"; Path = $InstallLog; Count = $installCount },
    @{ Name = "stdout"; Path = $stdoutLog; Count = $stdoutCount },
    @{ Name = "stderr"; Path = $stderrLog; Count = $stderrCount }
)) {
    if (Test-Path -LiteralPath $source.Path) {
        $lines = @(Get-Content -LiteralPath $source.Path -ErrorAction SilentlyContinue)
        for ($index = [int]$source.Count; $index -lt $lines.Count; $index++) {
            Publish-LiaisonLiveLine ([string]$source.Name) ([string]$lines[$index])
        }
    }
}

if ($process.ExitCode -eq 0) {
    Write-LiaisonProgress 86 "サーバー構成完了" "WSL、Docker、Liaison Serviceの設定が完了しました。"
} else {
    Write-LiaisonUnifiedLog ("Installation failed: Server core exited with code " + $process.ExitCode + ".")
}

exit $process.ExitCode
