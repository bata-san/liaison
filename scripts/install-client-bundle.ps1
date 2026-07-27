param(
    [string]$ConnectionFile,
    [switch]$SkipDependencyInstall,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "bootstrap-dependencies.ps1")

function Find-LiaisonConnectionFile([string]$RequestedPath) {
    $candidates = @()
    if ($RequestedPath) {
        $candidates += $RequestedPath
    }
    $candidates += @(
        (Join-Path $Root "liaison-client.json"),
        (Join-Path (Get-Location) "liaison-client.json"),
        (Join-Path $env:USERPROFILE "Desktop\liaison-client.json"),
        (Join-Path $env:USERPROFILE "Downloads\liaison-client.json")
    )
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if ($candidate -and (Test-Path $candidate)) {
            return (Resolve-Path $candidate).Path
        }
    }
    return $null
}

$resolved = Find-LiaisonConnectionFile $ConnectionFile
$connection = $null
if ($resolved) {
    try {
        $connection = Get-Content $resolved -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "The optional connection file could not be read."
        $resolved = $null
    }
}

Add-LiaisonToolPaths | Out-Null
if (-not $SkipDependencyInstall) {
    $needsTailscale = (-not $connection) -or ([string]$connection.transport) -eq "tailscale"
    if ($needsTailscale) {
        $tailscaleIp = Connect-LiaisonTailscale -InstallIfMissing
        if (-not $tailscaleIp) {
            Write-Warning "Tailscale login was not completed. Liaison Client will still be installed."
        }
    }
}

$arguments = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", (Join-Path $PSScriptRoot "setup-client.ps1"),
    "-SkipBuild"
)
if ($resolved) {
    $arguments += @("-ConnectionFile", $resolved)
}
if ($NoLaunch) {
    $arguments += "-NoLaunch"
}

& powershell.exe @arguments
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
