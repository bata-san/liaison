param(
    [ValidateSet("wsl-docker", "mock")]
    [string]$Runtime = "wsl-docker",
    [string]$WslDistribution = "LiaisonRuntime",
    [ValidateRange(1024, 65535)]
    [int]$Port = 57841,
    [string]$InstallDirectory = "$env:ProgramFiles\Liaison Server",
    [string]$ConfigDirectory = "$env:ProgramData\Liaison",
    [string]$ConnectionFile = "$env:USERPROFILE\Desktop\liaison-client.json",
    [switch]$LocalOnly,
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$TaskName = "LiaisonServer"
$FirewallRuleName = "Liaison Server (Tailscale)"
$Root = Split-Path -Parent $PSScriptRoot
$PackagedBin = Join-Path $Root "bin"

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Require-Command([string]$Name, [string]$InstallHint) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name was not found. $InstallHint"
    }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-RandomToken {
    $bytes = New-Object byte[] 32
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    } finally {
        $generator.Dispose()
    }
    return -join ($bytes | ForEach-Object { $_.ToString("x2") })
}

function Get-WslDistributions {
    $items = & wsl.exe --list --quiet 2>$null
    return @($items | ForEach-Object { ([string]$_).Replace([char]0, "").Trim() } | Where-Object { $_ })
}

function Get-TailscaleIPv4 {
    $tailscale = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if (-not $tailscale) {
        return $null
    }

    $candidate = (& $tailscale.Source ip -4 2>$null | Select-Object -First 1)
    if (-not $candidate) {
        return $null
    }

    $candidate = ([string]$candidate).Trim()
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($candidate, [ref]$parsed)) {
        return $null
    }

    $bytes = $parsed.GetAddressBytes()
    if ($bytes.Length -ne 4 -or $bytes[0] -ne 100 -or $bytes[1] -lt 64 -or $bytes[1] -gt 127) {
        return $null
    }
    return $candidate
}

if (-not (Test-Administrator)) {
    throw "Open PowerShell as Administrator and run this script again."
}

Write-Step "Checking server prerequisites"
$SelectedDistribution = $WslDistribution
if ($Runtime -eq "wsl-docker") {
    Require-Command "wsl.exe" "Enable Windows Subsystem for Linux first."
    $distributions = Get-WslDistributions
    if ($distributions.Count -eq 0) {
        throw "No WSL distribution was found. Run 'wsl --install -d Ubuntu' first."
    }
    if ($distributions -notcontains $SelectedDistribution) {
        $SelectedDistribution = $distributions | Where-Object { $_ -notlike "docker-desktop*" } | Select-Object -First 1
    }
    if (-not $SelectedDistribution) {
        throw "No usable WSL distribution was found."
    }

    & wsl.exe -d $SelectedDistribution -- docker version --format '{{.Server.Version}}' *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker is not available inside WSL distribution '$SelectedDistribution'."
    }
    Write-Host "WSL: $SelectedDistribution / Docker: OK" -ForegroundColor Green
}

Push-Location $Root
try {
    $PackagedServer = Join-Path $PackagedBin "liaison-service.exe"
    $PackagedCli = Join-Path $PackagedBin "liaison-cli.exe"
    $UsePackagedBinaries = (Test-Path $PackagedServer) -and (Test-Path $PackagedCli)

    if ($UsePackagedBinaries) {
        Write-Step "Using packaged server binaries"
        $SourceServer = $PackagedServer
        $SourceCli = $PackagedCli
    } else {
        Write-Step "Building server binaries"
        Require-Command "cargo.exe" "Install Rust from https://rustup.rs"
        if (-not $SkipBuild) {
            cargo build --release -p liaison-service -p liaison-cli
            if ($LASTEXITCODE -ne 0) {
                throw "The server release build failed."
            }
        }
        $SourceServer = Join-Path $Root "target\release\liaison-service.exe"
        $SourceCli = Join-Path $Root "target\release\liaison-cli.exe"
    }

    if (-not (Test-Path $SourceServer) -or -not (Test-Path $SourceCli)) {
        throw "Server binaries are missing. Use the release ZIP or run without -SkipBuild."
    }

    Write-Step "Stopping an existing installation"
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

    $oldService = Get-Service -Name "LiaisonService" -ErrorAction SilentlyContinue
    if ($oldService) {
        Stop-Service -Name "LiaisonService" -Force -ErrorAction SilentlyContinue
        sc.exe delete LiaisonService | Out-Null
    }
    Get-Process -Name "liaison-service" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    Write-Step "Installing server files"
    New-Item -ItemType Directory -Force -Path $InstallDirectory, $ConfigDirectory | Out-Null
    $ServerExe = Join-Path $InstallDirectory "liaison-service.exe"
    $CliExe = Join-Path $InstallDirectory "liaison-cli.exe"
    Copy-Item $SourceServer $ServerExe -Force
    Copy-Item $SourceCli $CliExe -Force

    $ConfigPath = Join-Path $ConfigDirectory "liaison.json"
    $ExamplePath = Join-Path $Root "config\liaison.example.json"
    if (-not (Test-Path $ExamplePath)) {
        throw "Configuration template is missing: $ExamplePath"
    }
    $Config = Get-Content $ExamplePath -Raw | ConvertFrom-Json

    $Token = $null
    if (Test-Path $ConfigPath) {
        try {
            $Existing = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            if ($Existing.auth_token -and ([string]$Existing.auth_token).Length -ge 16 -and $Existing.auth_token -notlike "replace-*") {
                $Token = [string]$Existing.auth_token
            }
        } catch {
            Write-Warning "The previous configuration could not be read. A new one will be created."
        }
    }
    if (-not $Token) {
        $Token = New-RandomToken
    }

    $Config.listen_address = "127.0.0.1:$Port"
    $Config.auth_token = $Token
    $Config.runtime = $Runtime
    $Config.wsl_distribution = $SelectedDistribution
    $Config.data_directory = Join-Path $ConfigDirectory "runtime-data"
    $Config.auto_tune = $true
    [IO.File]::WriteAllText(
        $ConfigPath,
        ($Config | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false)
    )

    Write-Step "Registering automatic startup"
    $HostScript = Join-Path $InstallDirectory "start-server.ps1"
    $HostContent = "& `"$ServerExe`" --console --config `"$ConfigPath`""
    Set-Content -Path $HostScript -Value $HostContent -Encoding UTF8

    $CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $TaskArguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$HostScript`""
    $Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $TaskArguments
    $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $CurrentUser
    $Settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $Action `
        -Trigger $Trigger `
        -Settings $Settings `
        -User $CurrentUser `
        -RunLevel Highest `
        -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName

    Write-Step "Checking local server connection"
    $Ready = $false
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 250
        & $CliExe --address "127.0.0.1:$Port" --token $Token health *> $null
        if ($LASTEXITCODE -eq 0) {
            $Ready = $true
            break
        }
    }
    if (-not $Ready) {
        throw "The server was installed but did not pass its health check. Check scheduled task '$TaskName'."
    }

    $Transport = "local"
    $ClientAddress = "127.0.0.1:$Port"
    $TailscaleIp = $null
    if (-not $LocalOnly) {
        $TailscaleIp = Get-TailscaleIPv4
    }

    if ($TailscaleIp) {
        Write-Step "Configuring Tailscale client access"
        Set-Service -Name iphlpsvc -StartupType Automatic
        Start-Service -Name iphlpsvc -ErrorAction SilentlyContinue
        netsh interface portproxy delete v4tov4 listenaddress=$TailscaleIp listenport=$Port *> $null
        netsh interface portproxy add v4tov4 listenaddress=$TailscaleIp listenport=$Port connectaddress=127.0.0.1 connectport=$Port | Out-Null

        Remove-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue
        New-NetFirewallRule `
            -DisplayName $FirewallRuleName `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalAddress $TailscaleIp `
            -LocalPort $Port `
            -RemoteAddress "100.64.0.0/10" `
            -Profile Any | Out-Null

        $Transport = "tailscale"
        $ClientAddress = "${TailscaleIp}:$Port"
    } else {
        Remove-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue
        Write-Warning "No Tailscale IP was detected. The server is available only on this PC."
    }

    Write-Step "Creating the client connection file"
    $ConnectionDirectory = Split-Path -Parent $ConnectionFile
    if ($ConnectionDirectory) {
        New-Item -ItemType Directory -Force -Path $ConnectionDirectory | Out-Null
    }
    $Connection = [ordered]@{
        version = 1
        server_name = $env:COMPUTERNAME
        address = $ClientAddress
        token = $Token
        transport = $Transport
        created_at = [DateTimeOffset]::Now.ToString("o")
    }
    [IO.File]::WriteAllText(
        $ConnectionFile,
        ($Connection | ConvertTo-Json -Depth 5),
        [Text.UTF8Encoding]::new($false)
    )

    Write-Host "`nServer setup completed." -ForegroundColor Green
    Write-Host "Server address: $ClientAddress"
    Write-Host "Client connection file: $ConnectionFile"
    Write-Host "Copy liaison-client.json into the extracted client package and run setup-client.ps1." -ForegroundColor Yellow
} finally {
    Pop-Location
}
