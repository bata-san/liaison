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
if (-not $resolved) {
    throw "liaison-client.json was not found. Copy the file created by the server into this folder."
}
$connection = Get-Content $resolved -Raw | ConvertFrom-Json

Add-LiaisonToolPaths | Out-Null
if (-not $SkipDependencyInstall -and ([string]$connection.transport) -eq "tailscale") {
    $tailscaleIp = Connect-LiaisonTailscale -InstallIfMissing
    if (-not $tailscaleIp) {
        throw "Tailscale sign-in is required for this server connection. Sign in to Tailscale and run setup again."
    }
}

$arguments = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", (Join-Path $PSScriptRoot "setup-client.ps1"),
    "-ConnectionFile", $resolved,
    "-SkipBuild"
)
if ($NoLaunch) {
    $arguments += "-NoLaunch"
}

& powershell.exe @arguments
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
