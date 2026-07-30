$ownershipHelper = Join-Path $PSScriptRoot "install-ownership.ps1"
if (-not (Test-Path -LiteralPath $ownershipHelper -PathType Leaf)) {
    throw ("Dependency ownership helper is missing: " + $ownershipHelper)
}
. $ownershipHelper

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

# Prefer Canonical's official Ubuntu WSL image and wsl --import. This path does not
# depend on Microsoft Store availability and provides byte-level download progress.
$directUbuntuInstaller = Join-Path $PSScriptRoot "wsl-install-direct.ps1"
if (-not (Test-Path -LiteralPath $directUbuntuInstaller -PathType Leaf)) {
    throw ("Direct Ubuntu WSL installer is missing: " + $directUbuntuInstaller)
}
. $directUbuntuInstaller

# This helper is loaded after the older WSL helpers so its virtualization preflight
# and UTF-16-aware native output reader override their basic implementations.
$virtualizationPreflight = Join-Path $PSScriptRoot "wsl-virtualization-preflight.ps1"
if (-not (Test-Path -LiteralPath $virtualizationPreflight -PathType Leaf)) {
    throw ("WSL virtualization preflight helper is missing: " + $virtualizationPreflight)
}
. $virtualizationPreflight

$progressHelper = Join-Path $PSScriptRoot "setup-progress.ps1"
if (Test-Path -LiteralPath $progressHelper -PathType Leaf) {
    . $progressHelper
    Write-LiaisonProgress 18 "Dependency check" "Checking Windows features, WSL, Docker, and Tailscale."
}
