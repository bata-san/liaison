from pathlib import Path


def replace_once(path: str, old: str, new: str, marker: str) -> None:
    file = Path(path)
    text = file.read_text(encoding="utf-8-sig")
    if marker in text:
        print(f"{path}: uninstall ownership already applied")
        return
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Expected exactly one patch location in {path}, found {count}")
    file.write_text(text.replace(old, new, 1), encoding="utf-8", newline="\n")
    print(f"{path}: uninstall ownership applied")


replace_once(
    "scripts/bootstrap-dependencies-core.ps1",
    '''    if (-not $installed) {
        throw "Tailscale installation did not complete."
    }
    return $installed''',
    '''    if (-not $installed) {
        throw "Tailscale installation did not complete."
    }
    Set-LiaisonOwnershipFlag -Name "tailscale_installed_by_liaison" -Value $true
    return $installed''',
    'Set-LiaisonOwnershipFlag -Name "tailscale_installed_by_liaison"',
)

replace_once(
    "scripts/wsl-virtualization-preflight.ps1",
    '''        Enable-WindowsOptionalFeature -Online -FeatureName $featureName -All -NoRestart -ErrorAction Stop | Out-Null
        $restartRequired = $true''',
    '''        Enable-WindowsOptionalFeature -Online -FeatureName $featureName -All -NoRestart -ErrorAction Stop | Out-Null
        if ($featureName -eq "Microsoft-Windows-Subsystem-Linux") {
            Set-LiaisonOwnershipFlag -Name "wsl_feature_enabled_by_liaison" -Value $true
        } elseif ($featureName -eq "VirtualMachinePlatform") {
            Set-LiaisonOwnershipFlag -Name "virtual_machine_platform_enabled_by_liaison" -Value $true
        }
        $restartRequired = $true''',
    'Set-LiaisonOwnershipFlag -Name "wsl_feature_enabled_by_liaison"',
)

replace_once(
    "scripts/wsl-virtualization-preflight.ps1",
    '''        Set-LiaisonBootHypervisorAuto
        $restartRequired = $true
    } elseif (-not $hypervisorPresent -and -not $restartRequired) {''',
    '''        Set-LiaisonBootHypervisorAuto
        Set-LiaisonHypervisorRepairOwnership -PreviousLaunchType ([string]$launchType)
        $restartRequired = $true
    } elseif (-not $hypervisorPresent -and -not $restartRequired) {''',
    'Set-LiaisonHypervisorRepairOwnership -PreviousLaunchType ([string]$launchType)',
)

replace_once(
    "scripts/wsl-virtualization-preflight.ps1",
    '''        Set-LiaisonBootHypervisorAuto
        $restartRequired = $true
    }

    if ($restartRequired) {''',
    '''        Set-LiaisonBootHypervisorAuto
        Set-LiaisonHypervisorRepairOwnership -PreviousLaunchType ([string]$launchType)
        $restartRequired = $true
    }

    if ($restartRequired) {''',
    'Set-LiaisonHypervisorRepairOwnership -PreviousLaunchType ([string]$launchType)\n        $restartRequired = $true\n    }\n\n    if ($restartRequired)',
)

replace_once(
    "scripts/wsl-install-direct.ps1",
    '''    if ($initResult.ExitCode -ne 0) {
        throw ("Ubuntu was imported but could not start. Windows may need a restart. " + (Get-LiaisonWslDetail $initResult))
    }
    Write-LiaisonProgress 43 "Ubuntu ready" "Ubuntu WSL started successfully."''',
    '''    if ($initResult.ExitCode -ne 0) {
        throw ("Ubuntu was imported but could not start. Windows may need a restart. " + (Get-LiaisonWslDetail $initResult))
    }
    Set-LiaisonOwnedWslDistribution -Distribution $Distribution -InstallPath $installLocation
    Write-LiaisonProgress 43 "Ubuntu ready" "Ubuntu WSL started successfully."''',
    'Set-LiaisonOwnedWslDistribution -Distribution $Distribution',
)

replace_once(
    "scripts/install-server-core.ps1",
    '''        if (-not (Test-LiaisonWslDocker -Distribution $Distribution)) {
            throw "Docker Engine was installed but did not become ready inside WSL distribution '$Distribution'. Check /var/log/liaison-dockerd.log."
        }
    }''',
    '''        if (-not (Test-LiaisonWslDocker -Distribution $Distribution)) {
            throw "Docker Engine was installed but did not become ready inside WSL distribution '$Distribution'. Check /var/log/liaison-dockerd.log."
        }
        Set-LiaisonOwnedDocker -Distribution $Distribution
    }''',
    'Set-LiaisonOwnedDocker -Distribution $Distribution',
)

replace_once(
    "scripts/install-server-core.ps1",
    '''    if (Test-Path $pairingPath) {
        Write-Host "Pairing code: $pairingPath"
    }
    Write-EarlyLog "Installation completed successfully."''',
    '''    if (Test-Path $pairingPath) {
        Write-Host "Pairing code: $pairingPath"
    }
    Set-LiaisonOwnershipFlag -Name "server_installed" -Value $true
    Write-EarlyLog "Installation completed successfully."''',
    'Set-LiaisonOwnershipFlag -Name "server_installed"',
)

replace_once(
    "scripts/install-client-bundle.ps1",
    '''& powershell.exe @arguments
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}''',
    '''& powershell.exe @arguments
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
Set-LiaisonOwnershipFlag -Name "client_installed" -Value $true''',
    'Set-LiaisonOwnershipFlag -Name "client_installed"',
)
