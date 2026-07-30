# Tracks dependencies that were installed or enabled by Liaison.
# Keep this file ASCII-only for Windows PowerShell 5.1 compatibility.

$script:LiaisonOwnershipPath = Join-Path $env:ProgramData "Liaison\install-ownership.json"

function New-LiaisonOwnershipState {
    return [ordered]@{
        version = 1
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
        server_installed = $false
        client_installed = $false
        updated_at = ""
    }
}

function Get-LiaisonOwnershipState {
    $state = New-LiaisonOwnershipState
    if (-not (Test-Path -LiteralPath $script:LiaisonOwnershipPath -PathType Leaf)) {
        return $state
    }

    try {
        $saved = Get-Content -LiteralPath $script:LiaisonOwnershipPath -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($property in @($state.Keys)) {
            if ($saved.PSObject.Properties.Name -contains $property) {
                $state[$property] = $saved.$property
            }
        }
    } catch {
        # A damaged ownership file must never block setup. Preserve it for diagnostics.
    }
    return $state
}

function Save-LiaisonOwnershipState($State) {
    $directory = Split-Path -Parent $script:LiaisonOwnershipPath
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $State.updated_at = [DateTimeOffset]::Now.ToString("o")
    [IO.File]::WriteAllText(
        $script:LiaisonOwnershipPath,
        (($State | ConvertTo-Json -Depth 6) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

function Set-LiaisonOwnershipFlag {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Value
    )

    $state = Get-LiaisonOwnershipState
    if (-not $state.Contains($Name)) {
        throw ("Unknown Liaison ownership flag: " + $Name)
    }
    if ($Value -or -not [bool]$state[$Name]) {
        $state[$Name] = $Value
    }
    Save-LiaisonOwnershipState $state
}

function Set-LiaisonOwnershipValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowEmptyString()][string]$Value
    )

    $state = Get-LiaisonOwnershipState
    if (-not $state.Contains($Name)) {
        throw ("Unknown Liaison ownership value: " + $Name)
    }
    $state[$Name] = $Value
    Save-LiaisonOwnershipState $state
}

function Set-LiaisonOwnedWslDistribution {
    param(
        [Parameter(Mandatory = $true)][string]$Distribution,
        [Parameter(Mandatory = $true)][string]$InstallPath
    )

    $state = Get-LiaisonOwnershipState
    $state.wsl_distribution_installed_by_liaison = $true
    $state.wsl_distribution_name = $Distribution
    $state.wsl_distribution_path = $InstallPath
    Save-LiaisonOwnershipState $state
}

function Set-LiaisonOwnedDocker {
    param([Parameter(Mandatory = $true)][string]$Distribution)

    $state = Get-LiaisonOwnershipState
    $state.docker_installed_by_liaison = $true
    $state.docker_distribution_name = $Distribution
    Save-LiaisonOwnershipState $state
}

function Set-LiaisonHypervisorRepairOwnership {
    param([AllowEmptyString()][string]$PreviousLaunchType)

    $state = Get-LiaisonOwnershipState
    if (-not [bool]$state.hypervisor_boot_repaired_by_liaison) {
        $state.hypervisor_launch_type_before = [string]$PreviousLaunchType
    }
    $state.hypervisor_boot_repaired_by_liaison = $true
    Save-LiaisonOwnershipState $state
}
