param(
    [string]$ConnectionFile,
    [string]$InstallDirectory = "$env:LOCALAPPDATA\Programs\Liaison Client",
    [switch]$SkipBuild,
    [switch]$NoDesktopShortcut,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$PackagedBin = Join-Path $Root "bin"
$ClientConfigDirectory = Join-Path $env:APPDATA "Liaison"
$ClientConfigPath = Join-Path $ClientConfigDirectory "client.json"

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Require-Command([string]$Name, [string]$InstallHint) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name was not found. $InstallHint"
    }
}

function Find-ConnectionFile([string]$RequestedPath) {
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

function New-Shortcut(
    [string]$ShortcutPath,
    [string]$LauncherPath,
    [string]$WorkingDirectory,
    [string]$IconPath
) {
    $directory = Split-Path -Parent $ShortcutPath
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$LauncherPath`""
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.IconLocation = "$IconPath,0"
    $shortcut.Description = "Liaison workstation client"
    $shortcut.Save()
}

Write-Step "Checking the client connection file"
$ResolvedConnectionFile = Find-ConnectionFile $ConnectionFile
if (-not $ResolvedConnectionFile) {
    throw "liaison-client.json was not found. Run setup-server.ps1 on the server and copy the generated JSON into the client package folder."
}

$Connection = Get-Content $ResolvedConnectionFile -Raw | ConvertFrom-Json
if (-not $Connection.address) {
    throw "The connection file does not contain an address: $ResolvedConnectionFile"
}
if (-not $Connection.token -or ([string]$Connection.token).Length -lt 16) {
    throw "The connection token is invalid: $ResolvedConnectionFile"
}
Write-Host "Server: $($Connection.address)" -ForegroundColor Green

Push-Location $Root
try {
    $PackagedClient = Join-Path $PackagedBin "liaison-desktop.exe"
    $PackagedCli = Join-Path $PackagedBin "liaison-cli.exe"
    $UsePackagedBinaries = (Test-Path $PackagedClient) -and (Test-Path $PackagedCli)

    if ($UsePackagedBinaries) {
        Write-Step "Using packaged client binaries"
        $SourceClient = $PackagedClient
        $SourceCli = $PackagedCli
    } else {
        Write-Step "Building client binaries"
        Require-Command "cargo.exe" "Install Rust from https://rustup.rs"
        Require-Command "npm.cmd" "Install Node.js 22 or newer."
        if (-not $SkipBuild) {
            npm --prefix apps/liaison-desktop install
            if ($LASTEXITCODE -ne 0) {
                throw "npm install failed."
            }
            npm --prefix apps/liaison-desktop run build
            if ($LASTEXITCODE -ne 0) {
                throw "The frontend build failed."
            }
            cargo build --release -p liaison-desktop -p liaison-cli
            if ($LASTEXITCODE -ne 0) {
                throw "The client release build failed."
            }
        }
        $SourceClient = Join-Path $Root "target\release\liaison-desktop.exe"
        $SourceCli = Join-Path $Root "target\release\liaison-cli.exe"
    }

    if (-not (Test-Path $SourceClient) -or -not (Test-Path $SourceCli)) {
        throw "Client binaries are missing. Use the release ZIP or run without -SkipBuild."
    }

    Write-Step "Installing the client"
    New-Item -ItemType Directory -Force -Path $InstallDirectory, $ClientConfigDirectory | Out-Null
    $ClientExe = Join-Path $InstallDirectory "liaison-desktop.exe"
    $CliExe = Join-Path $InstallDirectory "liaison-cli.exe"
    $LauncherPath = Join-Path $InstallDirectory "start-client.ps1"

    Get-Process -Name "liaison-desktop" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Copy-Item $SourceClient $ClientExe -Force
    Copy-Item $SourceCli $CliExe -Force
    Copy-Item (Join-Path $PSScriptRoot "start-client.ps1") $LauncherPath -Force

    $SavedConnection = [ordered]@{
        version = 1
        server_name = [string]$Connection.server_name
        address = [string]$Connection.address
        token = [string]$Connection.token
        transport = [string]$Connection.transport
        installed_at = [DateTimeOffset]::Now.ToString("o")
    }
    [IO.File]::WriteAllText(
        $ClientConfigPath,
        ($SavedConnection | ConvertTo-Json -Depth 5),
        [Text.UTF8Encoding]::new($false)
    )

    Write-Step "Creating shortcuts"
    $StartMenuShortcut = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Liaison Client.lnk"
    New-Shortcut $StartMenuShortcut $LauncherPath $InstallDirectory $ClientExe
    if (-not $NoDesktopShortcut) {
        $DesktopShortcut = Join-Path $env:USERPROFILE "Desktop\Liaison Client.lnk"
        New-Shortcut $DesktopShortcut $LauncherPath $InstallDirectory $ClientExe
    }

    Write-Step "Checking the server connection"
    & $CliExe --address ([string]$Connection.address) --token ([string]$Connection.token) health
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "The client was installed, but the server could not be reached. Check the server, Tailscale, and Windows Firewall."
    } else {
        Write-Host "Connection: OK" -ForegroundColor Green
    }

    Write-Host "`nClient setup completed." -ForegroundColor Green
    Write-Host "Open 'Liaison Client' from the desktop or Start menu."
    Write-Host "Client configuration: $ClientConfigPath"

    if (-not $NoLaunch) {
        & $LauncherPath
    }
} finally {
    Pop-Location
}
