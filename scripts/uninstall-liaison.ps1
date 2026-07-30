param(
    [switch]$RemoveData,
    [switch]$RemoveDependencies,
    [switch]$DisableWindowsFeatures,
    [string]$LogPath = "$env:ProgramData\Liaison\logs\uninstall.log"
)

# Keep this file ASCII-only for Windows PowerShell 5.1 compatibility.
$ErrorActionPreference = "Continue"
$restartRequired = $false
$warnings = New-Object Collections.Generic.List[string]

function Write-LiaisonUninstallLog([string]$Message) {
    $line = "{0} {1}" -f ([DateTimeOffset]::Now.ToString("o")), $Message
    try {
        $directory = Split-Path -Parent $LogPath
        if ($directory) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch {
    }
}

function Add-LiaisonUninstallWarning([string]$Message) {
    $warnings.Add($Message)
    Write-LiaisonUninstallLog ("WARNING|" + $Message)
}

function Invoke-LiaisonCleanupStep([string]$Name, [scriptblock]$Action) {
    Write-LiaisonUninstallLog ("STEP|" + $Name)
    try {
        & $Action
    } catch {
        Add-LiaisonUninstallWarning ($Name + ": " + $_.Exception.Message)
    }
}

function Get-LiaisonOwnershipForUninstall {
    $helperCandidates = @(
        (Join-Path $PSScriptRoot "install-ownership.ps1"),
        (Join-Path $env:ProgramData "Liaison\install-ownership.ps1")
    )
    foreach ($helper in $helperCandidates) {
        if (Test-Path -LiteralPath $helper -PathType Leaf) {
            try {
                . $helper
                return Get-LiaisonOwnershipState
            } catch {
                Add-LiaisonUninstallWarning ("Could not load dependency ownership information: " + $_.Exception.Message)
            }
        }
    }

    return [ordered]@{
        tailscale_installed_by_liaison = $false
        wsl_feature_enabled_by_liaison = $false
        virtual_machine_platform_enabled_by_liaison = $false
        hypervisor_boot_repaired_by_liaison = $false
        hypervisor_launch_type_before = ""
        wsl_distribution_installed_by_liaison = $false
        wsl_distribution_name = ""
        wsl_distribution_path = ""
        docker_installed_by_liaison = $false
        docker_distribution_name = ""
    }
}

function Remove-LiaisonPortProxy([int]$Port) {
    $raw = @(& "$env:SystemRoot\System32\netsh.exe" interface portproxy show v4tov4 2>$null)
    foreach ($line in $raw) {
        $match = [regex]::Match(([string]$line), '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s+(\d+)\s+(\d{1,3}(?:\.\d{1,3}){3})\s+(\d+)\s*$')
        if (-not $match.Success) { continue }
        $listenAddress = $match.Groups[1].Value
        $listenPort = [int]$match.Groups[2].Value
        $connectAddress = $match.Groups[3].Value
        $connectPort = [int]$match.Groups[4].Value
        if ($listenPort -eq $Port -and $connectAddress -eq "127.0.0.1" -and $connectPort -eq $Port) {
            & "$env:SystemRoot\System32\netsh.exe" interface portproxy delete v4tov4 listenaddress=$listenAddress listenport=$listenPort | Out-Null
        }
    }
}

function Remove-LiaisonTailscale {
    $registryRoots = @(
        "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    $productCodes = New-Object Collections.Generic.HashSet[string]
    foreach ($root in $registryRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            try {
                $item = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                if ([string]$item.DisplayName -notlike "Tailscale*") { continue }
                $text = ([string]$item.UninstallString) + " " + ([string]$item.QuietUninstallString) + " " + ([string]$key.PSChildName)
                $match = [regex]::Match($text, '\{[0-9A-Fa-f-]{36}\}')
                if ($match.Success) { [void]$productCodes.Add($match.Value) }
            } catch {
            }
        }
    }

    if ($productCodes.Count -eq 0) {
        Add-LiaisonUninstallWarning "Tailscale was marked as Liaison-installed, but its MSI product code was not found."
        return
    }

    foreach ($productCode in $productCodes) {
        $process = Start-Process -FilePath msiexec.exe -Wait -PassThru -ArgumentList @("/x", $productCode, "/qn", "/norestart")
        if ($process.ExitCode -notin @(0, 1605, 1614, 3010)) {
            Add-LiaisonUninstallWarning ("Tailscale uninstall returned exit code " + $process.ExitCode + ".")
        }
        if ($process.ExitCode -eq 3010) { $script:restartRequired = $true }
    }
}

function Remove-LiaisonDockerFromDistribution([string]$Distribution) {
    if (-not $Distribution) { return }
    $script = @'
set +e
if command -v service >/dev/null 2>&1; then service docker stop >/dev/null 2>&1 || true; fi
pkill dockerd >/dev/null 2>&1 || true
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
  apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io containerd runc >/dev/null 2>&1 || true
  apt-get autoremove -y >/dev/null 2>&1 || true
fi
rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.sources
rm -f /etc/apt/keyrings/docker.asc
exit 0
'@
    & "$env:SystemRoot\System32\wsl.exe" -d $Distribution -u root --exec sh -lc $script | Out-Null
}

Write-LiaisonUninstallLog "Liaison cleanup started."
$ownership = Get-LiaisonOwnershipForUninstall

$serverConfigPath = Join-Path $env:ProgramData "Liaison\liaison.json"
$serverPort = 57841
if (Test-Path -LiteralPath $serverConfigPath -PathType Leaf) {
    try {
        $serverConfig = Get-Content -LiteralPath $serverConfigPath -Raw | ConvertFrom-Json
        $listen = [string]$serverConfig.listen_address
        $match = [regex]::Match($listen, ':(\d+)$')
        if ($match.Success) { $serverPort = [int]$match.Groups[1].Value }
    } catch {
        Add-LiaisonUninstallWarning ("Could not read the Liaison server port: " + $_.Exception.Message)
    }
}

Invoke-LiaisonCleanupStep "Stop Liaison processes" {
    Get-Process -Name "liaison-desktop", "liaison-service" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

Invoke-LiaisonCleanupStep "Remove Liaison scheduled task" {
    Stop-ScheduledTask -TaskName "LiaisonServer" -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "LiaisonServer" -Confirm:$false -ErrorAction SilentlyContinue
}

Invoke-LiaisonCleanupStep "Remove Liaison firewall and port forwarding" {
    Remove-NetFirewallRule -DisplayName "Liaison Server (Tailscale)" -ErrorAction SilentlyContinue
    Remove-LiaisonPortProxy -Port $serverPort
}

Invoke-LiaisonCleanupStep "Remove Liaison client shortcuts" {
    Remove-Item -LiteralPath (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Liaison Client.lnk") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $env:USERPROFILE "Desktop\Liaison Client.lnk") -Force -ErrorAction SilentlyContinue
}

Invoke-LiaisonCleanupStep "Remove Liaison client and server files" {
    Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA "Programs\Liaison Client") -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $env:ProgramFiles "Liaison Server") -Recurse -Force -ErrorAction SilentlyContinue
}

if ($RemoveDependencies) {
    if ([bool]$ownership.docker_installed_by_liaison -and -not [bool]$ownership.wsl_distribution_installed_by_liaison) {
        Invoke-LiaisonCleanupStep "Remove Liaison-installed Docker Engine" {
            Remove-LiaisonDockerFromDistribution -Distribution ([string]$ownership.docker_distribution_name)
        }
    }

    if ([bool]$ownership.wsl_distribution_installed_by_liaison) {
        Invoke-LiaisonCleanupStep "Remove Liaison-installed WSL distribution" {
            $distribution = [string]$ownership.wsl_distribution_name
            if ($distribution) {
                & "$env:SystemRoot\System32\wsl.exe" --terminate $distribution 2>$null | Out-Null
                & "$env:SystemRoot\System32\wsl.exe" --unregister $distribution 2>$null | Out-Null
            }
            $distributionPath = [string]$ownership.wsl_distribution_path
            if ($distributionPath) {
                Remove-Item -LiteralPath $distributionPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ([bool]$ownership.tailscale_installed_by_liaison) {
        Invoke-LiaisonCleanupStep "Remove Liaison-installed Tailscale" {
            Remove-LiaisonTailscale
        }
    }

    if ($DisableWindowsFeatures) {
        if ([bool]$ownership.virtual_machine_platform_enabled_by_liaison) {
            Invoke-LiaisonCleanupStep "Disable VirtualMachinePlatform" {
                Disable-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform" -NoRestart -ErrorAction Stop | Out-Null
                $script:restartRequired = $true
            }
        }
        if ([bool]$ownership.wsl_feature_enabled_by_liaison) {
            Invoke-LiaisonCleanupStep "Disable Windows Subsystem for Linux" {
                Disable-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -NoRestart -ErrorAction Stop | Out-Null
                $script:restartRequired = $true
            }
        }
        if ([bool]$ownership.hypervisor_boot_repaired_by_liaison -and ([string]$ownership.hypervisor_launch_type_before) -ieq "Off") {
            Invoke-LiaisonCleanupStep "Restore hypervisor boot setting" {
                & "$env:SystemRoot\System32\bcdedit.exe" /set hypervisorlaunchtype off | Out-Null
                if ($LASTEXITCODE -eq 0) { $script:restartRequired = $true }
            }
        }
    }
}

if ($RemoveData) {
    Invoke-LiaisonCleanupStep "Remove Liaison data and pairing files" {
        Remove-Item -LiteralPath (Join-Path $env:APPDATA "Liaison") -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $env:USERPROFILE "Desktop\liaison-client.json") -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $env:USERPROFILE "Desktop\Liaison Pairing Code.txt") -Force -ErrorAction SilentlyContinue
    }

    # Delete ProgramData last because it contains this log and the ownership manifest.
    try {
        $programDataRoot = Join-Path $env:ProgramData "Liaison"
        if (Test-Path -LiteralPath $programDataRoot) {
            $cleanupCommand = 'Start-Sleep -Seconds 2; Remove-Item -LiteralPath ' + "'" + ($programDataRoot -replace "'", "''") + "'" + ' -Recurse -Force -ErrorAction SilentlyContinue'
            Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $cleanupCommand) | Out-Null
        }
    } catch {
        Add-LiaisonUninstallWarning ("Could not schedule ProgramData cleanup: " + $_.Exception.Message)
    }
}

Write-LiaisonUninstallLog ("Liaison cleanup completed. RestartRequired=" + $restartRequired + "; Warnings=" + $warnings.Count)
if ($restartRequired) {
    try {
        New-Item -ItemType Directory -Force -Path (Join-Path $env:ProgramData "Liaison") | Out-Null
        Set-Content -LiteralPath (Join-Path $env:ProgramData "Liaison\uninstall-restart-required.txt") -Value "1" -Encoding ASCII
    } catch {
    }
}

# Cleanup warnings should not prevent the application files from being uninstalled.
exit 0
