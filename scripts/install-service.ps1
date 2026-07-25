param(
    [string]$InstallDirectory = "$env:ProgramFiles\Liaison",
    [string]$ConfigDirectory = "$env:ProgramData\Liaison"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated PowerShell window."
}

Push-Location $Root
try {
    cargo build --release -p liaison-service -p liaison-cli
    if ($LASTEXITCODE -ne 0) { throw "Release build failed" }

    New-Item -ItemType Directory -Force -Path $InstallDirectory, $ConfigDirectory | Out-Null
    Copy-Item "target\release\liaison-service.exe" $InstallDirectory -Force
    Copy-Item "target\release\liaison-cli.exe" $InstallDirectory -Force

    $ConfigPath = Join-Path $ConfigDirectory "liaison.json"
    if (-not (Test-Path $ConfigPath)) {
        Copy-Item "config\liaison.example.json" $ConfigPath
        Write-Warning "Edit $ConfigPath and replace auth_token before starting the service."
    }

    $Existing = Get-Service -Name "LiaisonService" -ErrorAction SilentlyContinue
    if ($Existing) {
        Stop-Service -Name "LiaisonService" -Force -ErrorAction SilentlyContinue
        sc.exe delete LiaisonService | Out-Null
        Start-Sleep -Seconds 1
    }

    $Binary = Join-Path $InstallDirectory "liaison-service.exe"
    sc.exe create LiaisonService binPath= "`"$Binary`"" start= auto DisplayName= "Liaison Workstation Service" | Out-Null
    sc.exe description LiaisonService "Controls Liaison resource pools and local workstation modes." | Out-Null
    sc.exe failure LiaisonService reset= 86400 actions= restart/5000/restart/15000/""/0 | Out-Null

    Write-Host "Installed LiaisonService." -ForegroundColor Green
    Write-Host "After editing the token, run: Start-Service LiaisonService"
} finally {
    Pop-Location
}
