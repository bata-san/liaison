param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("server", "client")]
    [string]$Role,
    [Parameter(Mandatory = $true)]
    [string]$PayloadRoot,
    [Parameter(Mandatory = $true)]
    [string]$DashboardPath,
    [string]$UnifiedLogPath = (Join-Path $env:TEMP "LiaisonUnifiedSetup.log"),
    [switch]$LocalOnly
)

$ErrorActionPreference = "Stop"

function Write-UnifiedLog([string]$Message) {
    try {
        $line = "{0} {1}" -f ([DateTimeOffset]::Now.ToString("o")), $Message
        Add-Content -Path $UnifiedLogPath -Value $line -Encoding UTF8
    } catch {
        # Logging must not block setup.
    }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertFrom-LiaisonExtendedPath([string]$Path) {
    if (-not $Path) {
        return $Path
    }
    if ($Path.StartsWith("\\?\UNC\", [StringComparison]::OrdinalIgnoreCase)) {
        return "\\" + $Path.Substring(8)
    }
    if ($Path.StartsWith("\\?\", [StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring(4)
    }
    return $Path
}

function Get-LiaisonShortPath([string]$Path) {
    $Path = ConvertFrom-LiaisonExtendedPath $Path
    try {
        if (-not ("LiaisonUnifiedShortPath" -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class LiaisonUnifiedShortPath
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint GetShortPathName(
        string longPath,
        StringBuilder shortPath,
        uint bufferLength);
}
'@
        }

        $buffer = New-Object Text.StringBuilder 2048
        $length = [LiaisonUnifiedShortPath]::GetShortPathName($Path, $buffer, [uint32]$buffer.Capacity)
        if ($length -gt 0 -and $length -lt $buffer.Capacity) {
            return $buffer.ToString()
        }
    } catch {
        Write-UnifiedLog ("Short-path conversion failed: " + $_.Exception.Message)
    }
    return $Path
}

function Quote-ProcessArgument([string]$Value) {
    if ($null -eq $Value) { return '""' }
    if ($Value.Contains('"')) {
        throw "A setup argument contains an unsupported quote character."
    }
    return '"' + $Value + '"'
}

function New-LiaisonShortcut(
    [string]$ShortcutPath,
    [string]$TargetPath
) {
    $directory = Split-Path -Parent $ShortcutPath
    if ($directory) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $TargetPath
    $shortcut.WorkingDirectory = Split-Path -Parent $TargetPath
    $shortcut.IconLocation = "$TargetPath,0"
    $shortcut.Description = "Liaison workstation management"
    $shortcut.Save()
}

$PayloadRoot = ConvertFrom-LiaisonExtendedPath $PayloadRoot
$DashboardPath = ConvertFrom-LiaisonExtendedPath $DashboardPath
Write-UnifiedLog "Unified setup entered. Role: $Role"

if (-not (Test-Administrator)) {
    try {
        $elevatedScript = Get-LiaisonShortPath $PSCommandPath
        $elevatedPayload = Get-LiaisonShortPath $PayloadRoot
        $elevatedDashboard = Get-LiaisonShortPath $DashboardPath
        $argumentParts = @(
            "-NoLogo",
            "-NoProfile",
            "-WindowStyle", "Hidden",
            "-ExecutionPolicy", "Bypass",
            "-File", (Quote-ProcessArgument $elevatedScript),
            "-Role", (Quote-ProcessArgument $Role),
            "-PayloadRoot", (Quote-ProcessArgument $elevatedPayload),
            "-DashboardPath", (Quote-ProcessArgument $elevatedDashboard),
            "-UnifiedLogPath", (Quote-ProcessArgument $UnifiedLogPath)
        )
        if ($LocalOnly) { $argumentParts += "-LocalOnly" }
        $argumentLine = $argumentParts -join " "

        Write-UnifiedLog "Requesting administrator elevation."
        $process = Start-Process `
            -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -Verb RunAs `
            -WindowStyle Hidden `
            -Wait `
            -PassThru `
            -ArgumentList $argumentLine
        Write-UnifiedLog "Elevated unified setup exited with code $($process.ExitCode)."
        exit $process.ExitCode
    } catch {
        Write-UnifiedLog ("Administrator elevation failed: " + $_.Exception.Message)
        exit 1
    }
}

try {
    Write-UnifiedLog "Administrator unified setup started."
    if (-not (Test-Path -LiteralPath $PayloadRoot)) {
        throw "The staged setup payload is missing: $PayloadRoot"
    }
    if (-not (Test-Path -LiteralPath $DashboardPath -PathType Leaf)) {
        throw "The bundled Liaison application is missing: $DashboardPath"
    }

    $scripts = Join-Path $PayloadRoot "scripts"
    if ($Role -eq "server") {
        $serverInstaller = Join-Path $scripts "install-server-bundle.ps1"
        if (-not (Test-Path -LiteralPath $serverInstaller -PathType Leaf)) {
            throw "The server installer is missing: $serverInstaller"
        }

        $serverInstallLog = Join-Path $env:TEMP "LiaisonServerInstall.log"
        $arguments = @{
            LauncherLogPath = $UnifiedLogPath
            InstallLogPath = $serverInstallLog
        }
        if ($LocalOnly) { $arguments.LocalOnly = $true }

        Write-UnifiedLog "Starting server dependency and service setup."
        & $serverInstaller @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Server setup failed with exit code $LASTEXITCODE."
        }

        $connectionSource = Join-Path $env:USERPROFILE "Desktop\liaison-client.json"
        if (Test-Path $connectionSource) {
            $connectionDirectory = Join-Path $env:APPDATA "Liaison"
            $connectionTarget = Join-Path $connectionDirectory "client.json"
            New-Item -ItemType Directory -Force -Path $connectionDirectory | Out-Null
            Copy-Item $connectionSource $connectionTarget -Force
            Write-UnifiedLog "Imported the server connection into Liaison."
        } else {
            Write-UnifiedLog "Server setup completed without a generated client connection file."
        }
    } else {
        $bootstrap = Join-Path $scripts "bootstrap-dependencies.ps1"
        if (-not (Test-Path -LiteralPath $bootstrap -PathType Leaf)) {
            throw "The dependency bootstrap script is missing: $bootstrap"
        }
        . $bootstrap
        Add-LiaisonToolPaths | Out-Null
        $tailscaleIp = Connect-LiaisonTailscale -InstallIfMissing
        if ($tailscaleIp) {
            Write-UnifiedLog "Tailscale is ready at $tailscaleIp."
        } else {
            Write-UnifiedLog "Tailscale login was not completed. Liaison can still be paired later."
        }
    }

    $startMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Liaison.lnk"
    $desktop = Join-Path $env:USERPROFILE "Desktop\Liaison.lnk"
    New-LiaisonShortcut $startMenu $DashboardPath
    New-LiaisonShortcut $desktop $DashboardPath

    foreach ($oldShortcut in @(
        (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Liaison Client.lnk"),
        (Join-Path $env:USERPROFILE "Desktop\Liaison Client.lnk")
    )) {
        Remove-Item $oldShortcut -Force -ErrorAction SilentlyContinue
    }

    Write-UnifiedLog "Unified setup completed successfully for role $Role."
    exit 0
} catch {
    Write-UnifiedLog ("Setup failed: " + $_.Exception.Message)
    exit 1
}
