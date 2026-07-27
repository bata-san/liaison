$ErrorActionPreference = "Stop"

function Write-LiaisonDependencyStep([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Get-LiaisonTailscaleExe {
    $command = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    $candidates = @(
        "$env:ProgramFiles\Tailscale\tailscale.exe",
        "$env:LOCALAPPDATA\Tailscale\tailscale.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }
    return $null
}

function Get-LiaisonTailscaleIPv4 {
    $tailscale = Get-LiaisonTailscaleExe
    if (-not $tailscale) {
        return $null
    }
    $candidate = (& $tailscale ip -4 2>$null | Select-Object -First 1)
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

function Install-LiaisonTailscale {
    $existing = Get-LiaisonTailscaleExe
    if ($existing) {
        return $existing
    }

    Write-LiaisonDependencyStep "Installing Tailscale from the official package server"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $index = Invoke-WebRequest -UseBasicParsing -Uri "https://pkgs.tailscale.com/stable/"
    $matches = [regex]::Matches($index.Content, 'href="(tailscale-setup-full-[0-9.]+\.exe)"')
    if ($matches.Count -eq 0) {
        throw "The current Tailscale installer could not be located on the official package server."
    }
    $name = $matches[$matches.Count - 1].Groups[1].Value
    $temporary = Join-Path ([IO.Path]::GetTempPath()) $name
    Invoke-WebRequest -UseBasicParsing -Uri ("https://pkgs.tailscale.com/stable/" + $name) -OutFile $temporary
    Start-Process -FilePath $temporary -Wait

    $installed = Get-LiaisonTailscaleExe
    if (-not $installed) {
        throw "Tailscale installation did not complete. Install Tailscale and run this setup again."
    }
    return $installed
}

function Connect-LiaisonTailscale {
    param([switch]$InstallIfMissing)

    $tailscale = Get-LiaisonTailscaleExe
    if (-not $tailscale -and $InstallIfMissing) {
        $tailscale = Install-LiaisonTailscale
    }
    if (-not $tailscale) {
        return $null
    }

    $ip = Get-LiaisonTailscaleIPv4
    if ($ip) {
        return $ip
    }

    Write-LiaisonDependencyStep "Connecting Tailscale"
    $gui = Join-Path (Split-Path -Parent $tailscale) "tailscale-ipn.exe"
    if (Test-Path $gui) {
        Start-Process -FilePath $gui -ErrorAction SilentlyContinue
    }
    & $tailscale up
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Tailscale sign-in was not completed."
        return $null
    }
    return Get-LiaisonTailscaleIPv4
}

function Get-LiaisonDockerExe {
    $command = Get-Command docker.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    $candidates = @(
        "$env:ProgramFiles\Docker\Docker\resources\bin\docker.exe",
        "$env:LOCALAPPDATA\Programs\Docker\Docker\resources\bin\docker.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }
    return $null
}

function Start-LiaisonDockerDesktop {
    $candidates = @(
        "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
        "$env:LOCALAPPDATA\Programs\Docker\Docker\Docker Desktop.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            Start-Process -FilePath $candidate -ErrorAction SilentlyContinue
            return
        }
    }
}

function Wait-LiaisonDocker {
    param([int]$TimeoutSeconds = 180)

    $docker = Get-LiaisonDockerExe
    if (-not $docker) {
        return $false
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        & $docker info *> $null
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Install-LiaisonDockerDesktop {
    $docker = Get-LiaisonDockerExe
    if (-not $docker) {
        Write-LiaisonDependencyStep "Installing Docker Desktop from Docker"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $installer = Join-Path ([IO.Path]::GetTempPath()) "Docker Desktop Installer.exe"
        Invoke-WebRequest -UseBasicParsing -Uri "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe" -OutFile $installer
        Start-Process -FilePath $installer -Wait -ArgumentList "install"
    }

    Start-LiaisonDockerDesktop
    if (-not (Wait-LiaisonDocker)) {
        throw "Docker Desktop is installed but not ready. Start Docker Desktop, complete its first-run prompts, and run setup again."
    }
    return Get-LiaisonDockerExe
}

function Add-LiaisonToolPaths {
    $paths = @(
        "$env:ProgramFiles\Docker\Docker\resources\bin",
        "$env:LOCALAPPDATA\Programs\Docker\Docker\resources\bin",
        "$env:ProgramFiles\Tailscale",
        "$env:LOCALAPPDATA\Tailscale"
    ) | Where-Object { Test-Path $_ }
    if ($paths.Count -gt 0) {
        $env:PATH = (($paths -join ";") + ";" + $env:PATH)
    }
    return $paths
}
