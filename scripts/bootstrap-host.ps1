param([switch]$Apply)

$ErrorActionPreference = "Stop"
Write-Host "Liaison host preflight" -ForegroundColor Cyan
Write-Host "This script only changes Windows features when -Apply is supplied."

$Checks = [ordered]@{
    "Windows edition" = (Get-ComputerInfo -Property WindowsProductName).WindowsProductName
    "WSL command" = [bool](Get-Command wsl.exe -ErrorAction SilentlyContinue)
    "Tailscale command" = [bool](Get-Command tailscale.exe -ErrorAction SilentlyContinue)
    "NVIDIA CLI" = [bool](Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue)
    "Rust" = [bool](Get-Command cargo.exe -ErrorAction SilentlyContinue)
    "Node.js" = [bool](Get-Command node.exe -ErrorAction SilentlyContinue)
}
$Checks.GetEnumerator() | Format-Table -AutoSize

if ($Apply) {
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -All -NoRestart | Out-Null
    Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart | Out-Null
    Write-Host "WSL features enabled. A Windows restart may be required." -ForegroundColor Yellow
}

Write-Host "Next safe test:" -ForegroundColor Green
Write-Host "  powershell -ExecutionPolicy Bypass -File scripts\run-demo.ps1"
