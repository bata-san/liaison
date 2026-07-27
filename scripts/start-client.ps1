param(
    [string]$ConfigPath = "$env:APPDATA\Liaison\client.json"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ConfigPath)) {
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show(
        "Client configuration was not found. Run setup-client.ps1 first.",
        "Liaison Client",
        "OK",
        "Error"
    ) | Out-Null
    exit 1
}

$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if (-not $Config.address -or -not $Config.token) {
    throw "The client configuration does not contain address or token: $ConfigPath"
}

$ClientExe = Join-Path $PSScriptRoot "liaison-desktop.exe"
if (-not (Test-Path $ClientExe)) {
    throw "The client executable was not found: $ClientExe"
}

$env:LIAISON_ADDRESS = [string]$Config.address
$env:LIAISON_TOKEN = [string]$Config.token
Start-Process -FilePath $ClientExe -WorkingDirectory $PSScriptRoot
