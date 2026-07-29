$coreBootstrap = Join-Path $PSScriptRoot "bootstrap-dependencies-core.ps1"
if (-not (Test-Path -LiteralPath $coreBootstrap -PathType Leaf)) {
    throw ("Core dependency bootstrap is missing: " + $coreBootstrap)
}
. $coreBootstrap

$progressHelper = Join-Path $PSScriptRoot "setup-progress.ps1"
if (Test-Path -LiteralPath $progressHelper -PathType Leaf) {
    . $progressHelper
    Write-LiaisonProgress 18 "依存関係を確認" "Windows機能、WSL、Docker、Tailscaleの状態を確認しています。"
}
