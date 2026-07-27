param(
    [string]$WslDistribution = "Ubuntu",
    [switch]$LocalOnly,
    [switch]$SkipDependencyInstall
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "bootstrap-dependencies.ps1")

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
    }

    Install-LiaisonDockerEngineInWsl -Distribution $WslDistribution

    if (-not $LocalOnly) {
        $tailscaleIp = Connect-LiaisonTailscale -InstallIfMissing
        if (-not $tailscaleIp) {
            Write-Warning "Tailscale is installed but not signed in. The server will be configured as local-only."
            $LocalOnly = $true
        }
    }
}

$arguments = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", (Join-Path $PSScriptRoot "setup-server.ps1"),
    "-WslDistribution", $WslDistribution,
    "-SkipBuild"
)
if ($LocalOnly) {
    $arguments += "-LocalOnly"
}

& powershell.exe @arguments
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
