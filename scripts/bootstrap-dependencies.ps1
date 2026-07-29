$coreBootstrap = Join-Path $PSScriptRoot "bootstrap-dependencies-core.ps1"
if (-not (Test-Path -LiteralPath $coreBootstrap -PathType Leaf)) {
    throw ("Core dependency bootstrap is missing: " + $coreBootstrap)
}
. $coreBootstrap

$wslResilience = Join-Path $PSScriptRoot "wsl-install-resilience.ps1"
if (-not (Test-Path -LiteralPath $wslResilience -PathType Leaf)) {
    throw ("WSL installation resilience helper is missing: " + $wslResilience)
}
. $wslResilience

$progressHelper = Join-Path $PSScriptRoot "setup-progress.ps1"
if (Test-Path -LiteralPath $progressHelper -PathType Leaf) {
    . $progressHelper
    Write-LiaisonProgress 18 "Dependency check" "Checking Windows features, WSL, Docker, and Tailscale."
}
