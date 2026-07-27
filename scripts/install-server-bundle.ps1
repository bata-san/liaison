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

function Write-EarlyLog([string]$Message) {
    try {
        $line = "{0} {1}" -f ([DateTimeOffset]::Now.ToString("o")), $Message
        Add-Content -Path $LauncherLog -Value $line -Encoding UTF8
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
        # Managed Windows environments commonly block -EncodedCommand. Use a normal
        # -File launch instead. Prefer the DOS 8.3 path so spaces, Japanese text and
        # parentheses cannot be reinterpreted by the elevated command line parser.
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
    if (-not (Test-Path $bootstrapPath)) {
        throw "Dependency bootstrap script is missing: $bootstrapPath"
    }
    . $bootstrapPath

    Add-LiaisonToolPaths | Out-Null

    if (-not $SkipDependencyInstall) {
        if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
            Write-LiaisonDependencyStep "Installing Windows Subsystem for Linux"
            & dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
            & dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
            throw "WSL was enabled. Restart Windows, then run Install Liaison Server.cmd again."
        }

        $distributions = Get-LiaisonWslDistributions
        if ($distributions -notcontains $WslDistribution) {
            Write-LiaisonDependencyStep "Installing the $WslDistribution WSL distribution"
            & wsl.exe --install -d $WslDistribution --no-launch
            if ($LASTEXITCODE -ne 0) {
                throw "The WSL distribution could not be installed. Restart Windows and run setup again."
            }
            & wsl.exe -d $WslDistribution -u root -- sh -lc "true"
            if ($LASTEXITCODE -ne 0) {
                throw "The WSL distribution was installed but could not be initialized. Restart Windows and run setup again."
            }
        }

        Install-LiaisonDockerEngineInWsl -Distribution $WslDistribution

        if (-not $LocalOnly) {
            $tailscaleIp = Connect-LiaisonTailscale -InstallIfMissing
            if (-not $tailscaleIp) {
                Write-Warning "Tailscale is not signed in. The server will be configured as local-only."
                $LocalOnly = $true
            }
        }
    }

    # The control server must start before Docker workers. Persistent workers are
    # started later by the resilient host script, so an image pull or container
    # failure cannot terminate the Liaison control service.
    $templatePath = Join-Path $Root "config\liaison.example.json"
    if (-not (Test-Path $templatePath)) {
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

    & (Join-Path $PSScriptRoot "repair-windows-server.ps1") -WslDistribution $WslDistribution
    if ($LASTEXITCODE -ne 0) {
        throw "The resilient Windows startup configuration failed."
    }

    Write-Host ""
    Write-Host "Liaison Server installation completed." -ForegroundColor Green
    Write-Host "Launcher log: $LauncherLog"
    Write-Host "Installation log: $InstallLog"
    Write-Host "Runtime logs: $env:ProgramData\Liaison\logs"
    $pairingPath = Join-Path $env:USERPROFILE "Desktop\Liaison Pairing Code.txt"
    if (Test-Path $pairingPath) {
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
