param(
    [string]$ConfigPath = "$env:APPDATA\Liaison\client.json"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ConfigPath)) {
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show(
        "クライアント設定がありません。setup-client.ps1を先に実行してください。",
        "Liaison Client",
        "OK",
        "Error"
    ) | Out-Null
    exit 1
}

$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if (-not $Config.address -or -not $Config.token) {
    throw "クライアント設定にaddressまたはtokenがありません: $ConfigPath"
}

$ClientExe = Join-Path $PSScriptRoot "liaison-desktop.exe"
if (-not (Test-Path $ClientExe)) {
    throw "クライアント本体がありません: $ClientExe"
}

$env:LIAISON_ADDRESS = [string]$Config.address
$env:LIAISON_TOKEN = [string]$Config.token
Start-Process -FilePath $ClientExe -WorkingDirectory $PSScriptRoot
