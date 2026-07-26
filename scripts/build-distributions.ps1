param(
    [string]$OutputDirectory,
    [switch]$SkipTests,
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $Root "dist"
}

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Require-Command([string]$Name, [string]$InstallHint) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name was not found. $InstallHint"
    }
}

Require-Command "cargo.exe" "Install Rust from https://rustup.rs"
Require-Command "npm.cmd" "Install Node.js 22 or newer."

Push-Location $Root
try {
    if (-not $SkipBuild) {
        Write-Step "Building the frontend"
        npm --prefix apps/liaison-desktop install
        if ($LASTEXITCODE -ne 0) {
            throw "npm install failed."
        }
        npm --prefix apps/liaison-desktop run build
        if ($LASTEXITCODE -ne 0) {
            throw "The frontend build failed."
        }
    }

    if (-not $SkipTests) {
        Write-Step "Running tests"
        cargo test --workspace
        if ($LASTEXITCODE -ne 0) {
            throw "Rust tests failed."
        }
    }

    if (-not $SkipBuild) {
        Write-Step "Building release binaries"
        cargo build --release -p liaison-service -p liaison-cli -p liaison-desktop
        if ($LASTEXITCODE -ne 0) {
            throw "The release build failed."
        }
    }

    $RequiredBinaries = @(
        "target\release\liaison-service.exe",
        "target\release\liaison-cli.exe",
        "target\release\liaison-desktop.exe"
    )
    foreach ($binary in $RequiredBinaries) {
        if (-not (Test-Path $binary)) {
            throw "A release binary is missing: $binary"
        }
    }

    $ServerPackage = Join-Path $OutputDirectory "liaison-server"
    $ClientPackage = Join-Path $OutputDirectory "liaison-client"
    $ServerZip = Join-Path $OutputDirectory "liaison-server-windows.zip"
    $ClientZip = Join-Path $OutputDirectory "liaison-client-windows.zip"

    Remove-Item $ServerPackage, $ClientPackage -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $ServerZip, $ClientZip -Force -ErrorAction SilentlyContinue

    New-Item -ItemType Directory -Force -Path `
        (Join-Path $ServerPackage "bin"), `
        (Join-Path $ServerPackage "scripts"), `
        (Join-Path $ServerPackage "config"), `
        (Join-Path $ClientPackage "bin"), `
        (Join-Path $ClientPackage "scripts") | Out-Null

    Write-Step "Creating the server package"
    Copy-Item "target\release\liaison-service.exe" (Join-Path $ServerPackage "bin")
    Copy-Item "target\release\liaison-cli.exe" (Join-Path $ServerPackage "bin")
    Copy-Item "scripts\setup-server.ps1" (Join-Path $ServerPackage "scripts")
    Copy-Item "config\liaison.example.json" (Join-Path $ServerPackage "config")
    @'
Liaison Server

1. Extract this ZIP on the server PC.
2. Open PowerShell as Administrator in the extracted folder.
3. Run:

   powershell -ExecutionPolicy Bypass -File .\scripts\setup-server.ps1

The setup creates liaison-client.json on the desktop.
Copy that JSON file into the extracted client package folder.
'@ | Set-Content -Path (Join-Path $ServerPackage "README.txt") -Encoding UTF8

    Write-Step "Creating the client package"
    Copy-Item "target\release\liaison-desktop.exe" (Join-Path $ClientPackage "bin")
    Copy-Item "target\release\liaison-cli.exe" (Join-Path $ClientPackage "bin")
    Copy-Item "scripts\setup-client.ps1" (Join-Path $ClientPackage "scripts")
    Copy-Item "scripts\start-client.ps1" (Join-Path $ClientPackage "scripts")
    @'
Liaison Client

1. Extract this ZIP on the client PC.
2. Copy liaison-client.json from the server into this folder.
3. Open a normal PowerShell window and run:

   powershell -ExecutionPolicy Bypass -File .\scripts\setup-client.ps1

After setup, open Liaison Client from the desktop or Start menu.
'@ | Set-Content -Path (Join-Path $ClientPackage "README.txt") -Encoding UTF8

    Compress-Archive -Path (Join-Path $ServerPackage "*") -DestinationPath $ServerZip -CompressionLevel Optimal
    Compress-Archive -Path (Join-Path $ClientPackage "*") -DestinationPath $ClientZip -CompressionLevel Optimal

    Write-Host "`nDistribution packages created." -ForegroundColor Green
    Write-Host "Server: $ServerZip"
    Write-Host "Client: $ClientZip"
} finally {
    Pop-Location
}
