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
        Set-Service -Name Tailscale -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name Tailscale -ErrorAction SilentlyContinue
        return $existing
    }

    Write-LiaisonDependencyStep "Installing the Tailscale background service"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $index = Invoke-WebRequest -UseBasicParsing -Uri "https://pkgs.tailscale.com/stable/"
    $matches = [regex]::Matches($index.Content, 'href="(tailscale-setup-[0-9.]+-amd64\.msi)"')
    if ($matches.Count -eq 0) {
        throw "The current Tailscale MSI could not be located on the official package server."
    }
    $name = $matches[$matches.Count - 1].Groups[1].Value
    $temporary = Join-Path ([IO.Path]::GetTempPath()) $name
    Invoke-WebRequest -UseBasicParsing -Uri ("https://pkgs.tailscale.com/stable/" + $name) -OutFile $temporary

    $arguments = @(
        "/i", "`"$temporary`"",
        "/qn", "/norestart",
        "TS_NOLAUNCH=1",
        "TS_UNATTENDEDMODE=always",
        "TS_ONBOARDING_FLOW=hide"
    )
    $process = Start-Process -FilePath msiexec.exe -Wait -PassThru -ArgumentList $arguments
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "Tailscale MSI installation failed with exit code $($process.ExitCode)."
    }

    Set-Service -Name Tailscale -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name Tailscale -ErrorAction SilentlyContinue
    $installed = Get-LiaisonTailscaleExe
    if (-not $installed) {
        throw "Tailscale installation did not complete."
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

    Set-Service -Name Tailscale -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name Tailscale -ErrorAction SilentlyContinue
    $ip = Get-LiaisonTailscaleIPv4
    if ($ip) {
        return $ip
    }

    Write-LiaisonDependencyStep "Connecting the Tailscale background service"
    Write-Host "A browser login page may open once. Complete the login and return here."
    & $tailscale up --unattended=true
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Tailscale sign-in was not completed."
        return $null
    }
    return Get-LiaisonTailscaleIPv4
}

function Get-LiaisonWslDistributions {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        return @()
    }
    $items = & wsl.exe --list --quiet 2>$null
    return @($items | ForEach-Object { ([string]$_).Replace([char]0, "").Trim() } | Where-Object { $_ })
}

function Invoke-LiaisonWslRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Distribution,
        [Parameter(Mandatory = $true)][string]$Script
    )
    & wsl.exe -d $Distribution -u root -- sh -lc $Script
    if ($LASTEXITCODE -ne 0) {
        throw "A root command failed inside WSL distribution '$Distribution'."
    }
}

function Start-LiaisonWslDocker {
    param([Parameter(Mandatory = $true)][string]$Distribution)

    Invoke-LiaisonWslRoot -Distribution $Distribution -Script @'
set -eu
if docker info >/dev/null 2>&1; then
  exit 0
fi
if command -v service >/dev/null 2>&1; then
  service docker start >/dev/null 2>&1 || true
fi
if ! docker info >/dev/null 2>&1; then
  mkdir -p /var/log
  nohup dockerd > /var/log/liaison-dockerd.log 2>&1 &
fi
for i in $(seq 1 60); do
  docker info >/dev/null 2>&1 && exit 0
  sleep 1
done
exit 1
'@
}

function Test-LiaisonWslDocker {
    param([Parameter(Mandatory = $true)][string]$Distribution)
    & wsl.exe -d $Distribution -- docker version --format '{{.Server.Version}}' *> $null
    return $LASTEXITCODE -eq 0
}

function Install-LiaisonDockerEngineInWsl {
    param([Parameter(Mandatory = $true)][string]$Distribution)

    Write-LiaisonDependencyStep "Installing Docker Engine inside WSL"
    Invoke-LiaisonWslRoot -Distribution $Distribution -Script @'
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
'@

    $defaultUser = (& wsl.exe -d $Distribution -- sh -lc 'id -un' 2>$null | Select-Object -First 1)
    if ($defaultUser) {
        $safeUser = ([string]$defaultUser).Trim() -replace "[^A-Za-z0-9._-]", ""
        if ($safeUser) {
            Invoke-LiaisonWslRoot -Distribution $Distribution -Script "usermod -aG docker '$safeUser' || true"
        }
    }
    Start-LiaisonWslDocker -Distribution $Distribution
    if (-not (Test-LiaisonWslDocker -Distribution $Distribution)) {
        throw "Docker Engine was installed but did not become ready inside WSL."
    }
}

function Add-LiaisonToolPaths {
    $paths = @(
        "$env:ProgramFiles\Tailscale",
        "$env:LOCALAPPDATA\Tailscale"
    ) | Where-Object { Test-Path $_ }
    if ($paths.Count -gt 0) {
        $env:PATH = (($paths -join ";") + ";" + $env:PATH)
    }
    return $paths
}
