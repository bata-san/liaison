param(
    [string]$OutputDirectory,
    [switch]$SkipTests,
    [switch]$SkipBuild,
    [switch]$SkipInstallerExe
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

function Find-InnoSetupCompiler {
    $command = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    foreach ($candidate in @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    )) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }
    return $null
}

Require-Command "cargo.exe" "Install Rust from https://rustup.rs"
Require-Command "npm.cmd" "Install Node.js 22 or newer."

Push-Location $Root
try {
    if (-not $SkipBuild) {
        Write-Step "Building the frontend"
        npm --prefix apps/liaison-desktop install
        if ($LASTEXITCODE -ne 0) { throw "npm install failed." }
        npm --prefix apps/liaison-desktop run build
        if ($LASTEXITCODE -ne 0) { throw "The frontend build failed." }
    }

    if (-not $SkipTests) {
        Write-Step "Running tests"
        cargo test --workspace
        if ($LASTEXITCODE -ne 0) { throw "Rust tests failed." }
    }

    if (-not $SkipBuild) {
        Write-Step "Building release binaries"
        cargo build --release -p liaison-service -p liaison-cli -p liaison-desktop
        if ($LASTEXITCODE -ne 0) { throw "The release build failed." }
    }

    $RequiredBinaries = @(
        "target\release\liaison-service.exe",
        "target\release\liaison-cli.exe",
        "target\release\liaison-desktop.exe"
    )
    foreach ($binary in $RequiredBinaries) {
        if (-not (Test-Path $binary)) { throw "A release binary is missing: $binary" }
    }

    $ServerPackage = Join-Path $OutputDirectory "liaison-server-windows"
    $ClientPackage = Join-Path $OutputDirectory "liaison-client-windows"
    $UnifiedPackage = Join-Path $OutputDirectory "xliaison-windows"
    $ServerZip = Join-Path $OutputDirectory "liaison-server-windows.zip"
    $ClientZip = Join-Path $OutputDirectory "liaison-client-windows.zip"
    $UnifiedZip = Join-Path $OutputDirectory "xliaison-windows.zip"
    $SetupExe = Join-Path $OutputDirectory "xLiaison-Setup-Windows.exe"

    Remove-Item $ServerPackage, $ClientPackage, $UnifiedPackage -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $ServerZip, $ClientZip, $UnifiedZip, $SetupExe -Force -ErrorAction SilentlyContinue

    New-Item -ItemType Directory -Force -Path `
        (Join-Path $ServerPackage "bin"), `
        (Join-Path $ServerPackage "scripts"), `
        (Join-Path $ServerPackage "config"), `
        (Join-Path $ClientPackage "bin"), `
        (Join-Path $ClientPackage "scripts"), `
        (Join-Path $UnifiedPackage "bin"), `
        (Join-Path $UnifiedPackage "scripts"), `
        (Join-Path $UnifiedPackage "config") | Out-Null

    Write-Step "Creating the Windows server package"
    Copy-Item "target\release\liaison-service.exe" (Join-Path $ServerPackage "bin")
    Copy-Item "target\release\liaison-cli.exe" (Join-Path $ServerPackage "bin")
    Copy-Item "config\liaison.example.json" (Join-Path $ServerPackage "config")
    Copy-Item "scripts\setup-server.ps1" (Join-Path $ServerPackage "scripts")
    Copy-Item "scripts\install-server-bundle.ps1" (Join-Path $ServerPackage "scripts")
    Copy-Item "scripts\bootstrap-dependencies.ps1" (Join-Path $ServerPackage "scripts")
    Copy-Item "scripts\repair-windows-server.ps1" (Join-Path $ServerPackage "scripts")
    Copy-Item "scripts\start-server-windows.ps1" (Join-Path $ServerPackage "scripts")
    Copy-Item "scripts\install-server-launcher.cmd" (Join-Path $ServerPackage "Install Liaison Server.cmd")
    @'
@echo off
cd /d "%~dp0"
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-server-windows.ps1"
set LIAISON_EXIT=%ERRORLEVEL%
echo.
pause
exit /b %LIAISON_EXIT%
'@ | Set-Content -Path (Join-Path $ServerPackage "Start Liaison Server.cmd") -Encoding ASCII
    @'
Liaison Server for Windows

1. Extract this ZIP completely before running it.
2. Double-click Install Liaison Server.cmd.
3. Approve the administrator prompt.
4. Restart Windows only when WSL is enabled for the first time.
5. Complete the one-time Tailscale browser login when prompted.
6. Copy the displayed liaison:// pairing code into Liaison Client.

The installer window always pauses before closing.
The launcher creates %TEMP%\LiaisonServerLauncher.log before PowerShell starts.
The installation transcript is %TEMP%\LiaisonServerInstall.log.
Use Start Liaison Server.cmd to start the installed server and show diagnostics.
Runtime logs are stored in C:\ProgramData\Liaison\logs.
Docker runs headlessly inside WSL. Docker Desktop is not required.
Tailscale runs as a background service without opening its GUI.
The control server starts before P1/P2. A container failure no longer terminates the server.
'@ | Set-Content -Path (Join-Path $ServerPackage "README.txt") -Encoding ASCII

    Write-Step "Creating the Windows client package"
    Copy-Item "target\release\liaison-desktop.exe" (Join-Path $ClientPackage "bin")
    Copy-Item "target\release\liaison-cli.exe" (Join-Path $ClientPackage "bin")
    Copy-Item "scripts\setup-client.ps1" (Join-Path $ClientPackage "scripts")
    Copy-Item "scripts\start-client.ps1" (Join-Path $ClientPackage "scripts")
    Copy-Item "scripts\install-client-bundle.ps1" (Join-Path $ClientPackage "scripts")
    Copy-Item "scripts\bootstrap-dependencies.ps1" (Join-Path $ClientPackage "scripts")
    @'
@echo off
cd /d "%~dp0"
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install-client-bundle.ps1"
if errorlevel 1 pause
'@ | Set-Content -Path (Join-Path $ClientPackage "Install Liaison Client.cmd") -Encoding ASCII
    @'
Liaison Client for Windows

1. Extract this ZIP.
2. Double-click Install Liaison Client.cmd.
3. Complete the one-time Tailscale browser login when prompted.
4. Open Liaison Client and paste the server pairing code.

A liaison-client.json file is optional. The app saves connection settings itself.
Worker management and the workspace terminal are integrated into Liaison Client.
Tailscale runs as a background service without opening its GUI.
'@ | Set-Content -Path (Join-Path $ClientPackage "README.txt") -Encoding ASCII

    Write-Step "Creating the unified xLiaison package"
    Copy-Item "target\release\liaison-service.exe" (Join-Path $UnifiedPackage "bin")
    Copy-Item "target\release\liaison-cli.exe" (Join-Path $UnifiedPackage "bin")
    Copy-Item "target\release\liaison-desktop.exe" (Join-Path $UnifiedPackage "bin")
    Copy-Item "config\liaison.example.json" (Join-Path $UnifiedPackage "config")
    foreach ($script in @(
        "bootstrap-dependencies.ps1",
        "install-server-bundle.ps1",
        "install-client-bundle.ps1",
        "install-xliaison.ps1",
        "setup-server.ps1",
        "setup-client.ps1",
        "start-client.ps1",
        "repair-windows-server.ps1",
        "start-server-windows.ps1"
    )) {
        Copy-Item (Join-Path "scripts" $script) (Join-Path $UnifiedPackage "scripts")
    }
    @'
@echo off
cd /d "%~dp0"
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install-xliaison.ps1"
set XLIAISON_EXIT=%ERRORLEVEL%
if not "%XLIAISON_EXIT%"=="0" pause
exit /b %XLIAISON_EXIT%
'@ | Set-Content -Path (Join-Path $UnifiedPackage "Install xLiaison.cmd") -Encoding ASCII
    @'
xLiaison for Windows

Use xLiaison-Setup-Windows.exe for the standard guided setup.
The setup lets you choose Client, Server, or both, then automates dependency
installation, configuration, startup registration, and connection checks.

The ZIP fallback can be used without Inno Setup:
1. Extract xliaison-windows.zip completely.
2. Double-click Install xLiaison.cmd.
3. Choose the role and approve the administrator prompt.

Server setup may require one Windows restart when WSL is enabled for the first
time. Setup is cached and registered to continue after the next sign-in.
A one-time Tailscale browser login may also be required. When Server and Client
are installed together, the generated connection information is imported into
the Client automatically.

Setup log: %TEMP%\xLiaisonSetup.log
Server install log: %TEMP%\LiaisonServerInstall.log
'@ | Set-Content -Path (Join-Path $UnifiedPackage "README.txt") -Encoding UTF8

    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    Compress-Archive -Path (Join-Path $ServerPackage "*") -DestinationPath $ServerZip -CompressionLevel Optimal
    Compress-Archive -Path (Join-Path $ClientPackage "*") -DestinationPath $ClientZip -CompressionLevel Optimal
    Compress-Archive -Path (Join-Path $UnifiedPackage "*") -DestinationPath $UnifiedZip -CompressionLevel Optimal

    if (-not $SkipInstallerExe) {
        $iscc = Find-InnoSetupCompiler
        if ($iscc) {
            Write-Step "Building xLiaison Setup.exe"
            & $iscc "installer\xliaison.iss"
            if ($LASTEXITCODE -ne 0) {
                throw "Inno Setup failed to build xLiaison-Setup-Windows.exe."
            }
            if (-not (Test-Path $SetupExe)) {
                throw "The xLiaison setup executable was not created: $SetupExe"
            }
        } else {
            Write-Warning "Inno Setup 6 was not found. xliaison-windows.zip was created, but Setup.exe was skipped."
        }
    }

    Write-Host "`nDistribution packages created." -ForegroundColor Green
    Write-Host "Server: $ServerZip"
    Write-Host "Client: $ClientZip"
    Write-Host "Unified ZIP: $UnifiedZip"
    if (Test-Path $SetupExe) {
        Write-Host "Unified setup: $SetupExe"
    }
} finally {
    Pop-Location
}
