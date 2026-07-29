param(
    [string]$WslDistribution = "Ubuntu",
    [switch]$LocalOnly,
    [switch]$SkipDependencyInstall,
    [string]$LauncherLogPath,
    [string]$InstallLogPath
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$LauncherLog = if ($LauncherLogPath) { $LauncherLogPath } else { Join-Path $env:TEMP "LiaisonServerLauncher.log" }
$InstallLog = if ($InstallLogPath) { $InstallLogPath } else { Join-Path $env:TEMP "LiaisonServerInstall.log" }
$env:LIAISON_UNIFIED_LOG_PATH = $LauncherLog

function Write-EarlyLog([string]$Message) {
    try {
        $line = "{0} {1}" -f ([DateTimeOffset]::Now.ToString("o")), $Message
        Add-Content -LiteralPath $LauncherLog -Value $line -Encoding UTF8
    } catch {
        # Logging must never prevent setup from continuing.
    }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-LiaisonShortPath([string]$Path) {
    try {
        if (-not ("LiaisonShortPath" -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class LiaisonShortPath
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint GetShortPathName(
        string longPath,
        StringBuilder shortPath,
        uint bufferLength);
}
'@
        }

        $buffer = New-Object Text.StringBuilder 1024
        $length = [LiaisonShortPath]::GetShortPathName($Path, $buffer, [uint32]$buffer.Capacity)
        if ($length -gt 0 -and $length -lt $buffer.Capacity) {
            return $buffer.ToString()
        }
    } catch {
        Write-EarlyLog ("Short-path conversion failed; using the quoted full path: " + $_.Exception.Message)
    }

    return $Path
}

function Quote-LiaisonProcessArgument([string]$Value) {
    if ($null -eq $Value) {
        return '""'
    }
    if ($Value.Contains('"')) {
        throw "A process argument contains an unsupported quote character."
    }
    return '"' + $Value + '"'
}

Write-EarlyLog "PowerShell installer entered. Script: $PSCommandPath"

if (-not (Test-Administrator)) {
    try {
        $elevationScript = Get-LiaisonShortPath $PSCommandPath
        $argumentParts = @(
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", (Quote-LiaisonProcessArgument $elevationScript),
            "-WslDistribution", (Quote-LiaisonProcessArgument $WslDistribution),
            "-LauncherLogPath", (Quote-LiaisonProcessArgument $LauncherLog),
            "-InstallLogPath", (Quote-LiaisonProcessArgument $InstallLog)
        )
        if ($LocalOnly) { $argumentParts += "-LocalOnly" }
        if ($SkipDependencyInstall) { $argumentParts += "-SkipDependencyInstall" }
        $argumentLine = $argumentParts -join " "

        Write-EarlyLog "Requesting administrator elevation with a normal -File command."
        Write-EarlyLog "Elevated script path: $elevationScript"
        $process = Start-Process -FilePath "powershell.exe" -Verb RunAs -Wait -PassThru -ArgumentList $argumentLine
        Write-EarlyLog "Elevated installer exited with code $($process.ExitCode)."
        exit $process.ExitCode
    } catch {
        Write-EarlyLog ("Administrator elevation failed: " + $_.Exception.Message)
        Write-Host "Administrator elevation failed." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host "Launcher log: $LauncherLog"
        exit 1
    }
}

$transcriptStarted = $false
$exitCode = 0
try {
    Write-EarlyLog "Administrator installer started."
    try {
        Start-Transcript -Path $InstallLog -Append | Out-Null
        $transcriptStarted = $true
    } catch {
        Write-EarlyLog ("Installation transcript could not be started: " + $_.Exception.Message)
        Write-Warning "Installation transcript could not be started: $($_.Exception.Message)"
    }

    $bootstrapPath = Join-Path $PSScriptRoot "bootstrap-dependencies.ps1"
    $progressPath = Join-Path $PSScriptRoot "setup-progress.ps1"
    if (-not (Test-Path -LiteralPath $bootstrapPath -PathType Leaf)) {
        throw "Dependency bootstrap script is missing: $bootstrapPath"
    }
    if (-not (Test-Path -LiteralPath $progressPath -PathType Leaf)) {
        throw "Setup progress helper is missing: $progressPath"
    }
    . $bootstrapPath
    . $progressPath

    function Invoke-LiaisonWslRoot {
        param(
            [Parameter(Mandatory = $true)][string]$Distribution,
            [Parameter(Mandatory = $true)][string]$Script
        )

        $normalizedScript = $Script.Replace("`r`n", "`n").Replace("`r", "`n")
        $encodedScript = [Convert]::ToBase64String(
            [Text.UTF8Encoding]::new($false).GetBytes($normalizedScript)
        )
        $transportCommand = "printf %s $encodedScript | base64 -d | sh"

        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $rawOutput = & "$env:SystemRoot\System32\wsl.exe" -d $Distribution -u root --exec sh -lc $transportCommand 2>&1
            $nativeExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        $cleanOutput = @(
            $rawOutput |
                ForEach-Object { (([string]$_) -replace "\x00", "").TrimEnd() } |
                Where-Object { $_ }
        )
        foreach ($line in $cleanOutput) {
            Write-Host $line
            Write-EarlyLog ("WSL | " + $line)
        }

        if ($nativeExitCode -ne 0) {
            $tail = @($cleanOutput | Select-Object -Last 16)
            $detail = if ($tail.Count -gt 0) { $tail -join " | " } else { "No output was returned by WSL." }
            throw "A root command failed inside WSL distribution '$Distribution' with exit code $nativeExitCode. Last output: $detail"
        }
    }

    function Test-LiaisonWslDocker {
        param([Parameter(Mandatory = $true)][string]$Distribution)

        $previousErrorActionPreference = $ErrorActionPreference
        $nativeExitCode = 1
        try {
            $ErrorActionPreference = "Continue"
            & "$env:SystemRoot\System32\wsl.exe" -d $Distribution -u root --exec sh -lc "command -v docker >/dev/null 2>&1 && command -v dockerd >/dev/null 2>&1 && docker info >/dev/null 2>&1" 2>$null | Out-Null
            $nativeExitCode = $LASTEXITCODE
        } catch {
            $nativeExitCode = 1
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        return $nativeExitCode -eq 0
    }

    function Install-LiaisonDockerEngineInWsl {
        param([Parameter(Mandatory = $true)][string]$Distribution)

        Write-LiaisonDependencyStep "Installing Docker Engine inside WSL"
        Write-LiaisonProgress 38 "Dockerをインストール" "Ubuntuパッケージ一覧を更新し、Docker Engineを導入しています。"
        Invoke-LiaisonWslRoot -Distribution $Distribution -Script @'
set -eu
export DEBIAN_FRONTEND=noninteractive

if command -v docker >/dev/null 2>&1 && command -v dockerd >/dev/null 2>&1; then
  exit 0
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This WSL distribution does not provide apt-get. An Ubuntu or Debian distribution is required."
  exit 41
fi

rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.sources
apt-get update -o Acquire::Retries=3

if apt-get install -y ca-certificates curl docker.io; then
  exit 0
fi

echo "Ubuntu's docker.io package failed; trying Docker's official repository."
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl --retry 3 --retry-delay 2 -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update -o Acquire::Retries=3
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
'@

        $defaultUser = (& "$env:SystemRoot\System32\wsl.exe" -d $Distribution --exec sh -lc 'id -un' 2>$null | Select-Object -First 1)
        if ($defaultUser) {
            $safeUser = ([string]$defaultUser).Trim() -replace "[^A-Za-z0-9._-]", ""
            if ($safeUser -and $safeUser -ne "root") {
                Invoke-LiaisonWslRoot -Distribution $Distribution -Script "usermod -aG docker '$safeUser' || true"
            }
        }

        Write-LiaisonProgress 50 "Dockerを起動" "Dockerデーモンを起動し、応答可能になるまで確認しています。"
        Start-LiaisonWslDocker -Distribution $Distribution
        if (-not (Test-LiaisonWslDocker -Distribution $Distribution)) {
            throw "Docker Engine was installed but did not become ready inside WSL distribution '$Distribution'. Check /var/log/liaison-dockerd.log."
        }
        Write-LiaisonProgress 55 "Docker準備完了" "Docker Engineがコマンドを受け付ける状態になりました。"
    }

    Add-LiaisonToolPaths | Out-Null

    if (-not $SkipDependencyInstall) {
        Write-LiaisonProgress 18 "WSL機能を確認" "Windows Subsystem for Linuxと仮想マシンプラットフォームを確認しています。"
        Ensure-LiaisonWslFeatures

        Write-LiaisonProgress 24 "Ubuntuを確認" "利用可能なWSLディストリビューションを検索しています。"
        $installedDistributions = @(
            Get-LiaisonWslDistributions |
                Where-Object { $_ -and $_ -notlike "docker-desktop*" }
        )
        $selectedDistribution = $installedDistributions |
            Where-Object { $_ -ieq $WslDistribution } |
            Select-Object -First 1

        if (-not $selectedDistribution -and $WslDistribution -like "Ubuntu*") {
            $selectedDistribution = $installedDistributions |
                Where-Object { $_ -like "Ubuntu*" } |
                Sort-Object -Descending |
                Select-Object -First 1
        }

        if ($selectedDistribution) {
            if ($selectedDistribution -ine $WslDistribution) {
                Write-Host "Using installed WSL distribution '$selectedDistribution' instead of '$WslDistribution'." -ForegroundColor Green
                Write-EarlyLog "Using installed WSL distribution '$selectedDistribution' instead of '$WslDistribution'."
            } else {
                Write-Host "Using installed WSL distribution '$selectedDistribution'." -ForegroundColor Green
                Write-EarlyLog "Using installed WSL distribution '$selectedDistribution'."
            }
            $WslDistribution = [string]$selectedDistribution
        } else {
            Write-LiaisonProgress 27 "Ubuntuをインストール" "WSL用Ubuntuをダウンロードして初期化しています。"
            Ensure-LiaisonWslDistribution -Distribution $WslDistribution
        }
        Write-LiaisonProgress 31 "Ubuntu準備完了" "WSLディストリビューション '$WslDistribution' を使用します。"

        Write-LiaisonProgress 34 "Dockerを確認" "既存のDocker Engineが利用できるか確認しています。"
        if (Test-LiaisonWslDocker -Distribution $WslDistribution) {
            Write-Host "Using the existing Docker Engine in WSL distribution '$WslDistribution'." -ForegroundColor Green
            Write-EarlyLog "Using the existing Docker Engine in WSL distribution '$WslDistribution'."
            Write-LiaisonProgress 55 "Docker準備完了" "既存のDocker Engineを使用します。"
        } else {
            Install-LiaisonDockerEngineInWsl -Distribution $WslDistribution
        }

        if (-not $LocalOnly) {
            $tailscaleIp = Connect-LiaisonTailscaleInteractive `
                -InstallIfMissing `
                -WaitForLoginSeconds 0 `
                -ProgressStart 58 `
                -ProgressEnd 64
            if (-not $tailscaleIp) {
                Write-Warning "Tailscale is not signed in. The server will be configured as local-only."
                Write-EarlyLog "Tailscale login is pending; continuing with local-only server configuration."
                $LocalOnly = $true
            }
        } else {
            Write-LiaisonProgress 64 "ローカル接続を使用" "Tailscaleを使用せず、このPC内の接続だけを構成します。"
        }
    }

    Write-LiaisonProgress 68 "サーバー設定を作成" "Liaison Serviceの設定ファイルと実行パラメーターを準備しています。"
    $templatePath = Join-Path $Root "config\liaison.example.json"
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw "Configuration template is missing: $templatePath"
    }
    $template = Get-Content $templatePath -Raw | ConvertFrom-Json
    if ($template.PSObject.Properties.Name -contains "persistent_autostart") {
        $template.persistent_autostart = $false
    } else {
        $template | Add-Member -NotePropertyName persistent_autostart -NotePropertyValue $false
    }
    [IO.File]::WriteAllText(
        $templatePath,
        ($template | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false)
    )

    Write-LiaisonProgress 72 "Liaison Serviceを導入" "サーバーバイナリ、設定ファイル、管理用接続情報を配置しています。"
    $setupArguments = @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $PSScriptRoot "setup-server.ps1"),
        "-WslDistribution", $WslDistribution,
        "-SkipBuild"
    )
    if ($LocalOnly) { $setupArguments += "-LocalOnly" }

    & powershell.exe @setupArguments
    if ($LASTEXITCODE -ne 0) {
        throw "The base Liaison Server setup failed with exit code $LASTEXITCODE."
    }

    Write-LiaisonProgress 80 "Windows自動起動を設定" "PC起動後にLiaison ServiceとDockerが復旧するよう登録しています。"
    & (Join-Path $PSScriptRoot "repair-windows-server.ps1") -WslDistribution $WslDistribution
    if ($LASTEXITCODE -ne 0) {
        throw "The resilient Windows startup configuration failed."
    }

    Write-LiaisonProgress 86 "サーバー構成完了" "Liaison Service、Docker、Windows自動起動の設定が完了しました。"
    Write-Host ""
    Write-Host "Liaison Server installation completed." -ForegroundColor Green
    Write-Host "Launcher log: $LauncherLog"
    Write-Host "Installation log: $InstallLog"
    Write-Host "Runtime logs: $env:ProgramData\Liaison\logs"
    $pairingPath = Join-Path $env:USERPROFILE "Desktop\Liaison Pairing Code.txt"
    if (Test-Path -LiteralPath $pairingPath) {
        Write-Host "Pairing code: $pairingPath"
    }
    Write-EarlyLog "Installation completed successfully."
} catch {
    $exitCode = 1
    Write-EarlyLog ("Installation failed: " + $_.Exception.Message)
    Write-Host ""
    Write-Host "Liaison Server installation failed." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Launcher log: $LauncherLog"
    Write-Host "Installation log: $InstallLog"
    Write-Host "Runtime logs: $env:ProgramData\Liaison\logs"
} finally {
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
}

exit $exitCode
