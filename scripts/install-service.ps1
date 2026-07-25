#requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

$repositoryRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Push-Location $repositoryRoot
try {
    cargo build --release -p liaison-service
    $binary = Join-Path $repositoryRoot "target\release\liaison-service.exe"

    $existing = Get-Service -Name "LiaisonService" -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.Status -ne "Stopped") {
            Stop-Service -Name "LiaisonService" -Force
        }
        sc.exe delete LiaisonService | Out-Null
        Start-Sleep -Milliseconds 500
    }

    New-Service `
        -Name "LiaisonService" `
        -BinaryPathName ('"{0}"' -f $binary) `
        -DisplayName "Liaison Workstation Service" `
        -Description "Controls Liaison resource pools and workstation operating modes." `
        -StartupType Automatic

    Start-Service -Name "LiaisonService"
    Write-Host "LiaisonService installed and started."
}
finally {
    Pop-Location
}
