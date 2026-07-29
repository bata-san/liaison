param(
    [string]$ConnectionFile,
    [switch]$SkipDependencyInstall,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "bootstrap-dependencies.ps1")

function Find-LiaisonConnectionFile([string]$RequestedPath) {
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

function Invoke-LiaisonTailscaleCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $rawOutput = @()
    $exitCode = -1
    try {
        # `tailscale ip` writes NeedsLogin to stderr. With the setup-wide Stop
        # preference that must remain a normal command result, not abort setup.
        $ErrorActionPreference = "Continue"
        $rawOutput = @(& $Executable @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } catch {
        $rawOutput = @($_.Exception.Message)
        $exitCode = -1
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $output = @(
        $rawOutput |
            ForEach-Object { (([string]$_) -replace "\x00", "").Trim() } |
            Where-Object { $_ }
    )

    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Output = $output
    }
}

function Get-LiaisonClientTailscaleIPv4 {
    param([Parameter(Mandatory = $true)][string]$Executable)

    $result = Invoke-LiaisonTailscaleCommand -Executable $Executable -Arguments @("ip", "-4")
    if ($result.ExitCode -ne 0) {
        return $null
    }

    foreach ($line in @($result.Output)) {
        $candidate = ([string]$line).Trim()
        $parsed = $null
        if (-not [Net.IPAddress]::TryParse($candidate, [ref]$parsed)) {
            continue
        }
        $bytes = $parsed.GetAddressBytes()
        if ($bytes.Length -eq 4 -and $bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127) {
            return $candidate
        }
    }
    return $null
}

function Connect-LiaisonClientTailscale {
    param([switch]$InstallIfMissing)

    $tailscale = Get-LiaisonTailscaleExe
    if (-not $tailscale -and $InstallIfMissing) {
        $tailscale = Install-LiaisonTailscale
    }
    if (-not $tailscale) {
        Write-Host "LIAISON_TAILSCALE_LOGIN_REQUIRED"
        Write-Warning "Tailscale is not installed. Liaison Client installation will continue."
        return $null
    }

    Set-Service -Name Tailscale -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name Tailscale -ErrorAction SilentlyContinue

    $ip = Get-LiaisonClientTailscaleIPv4 -Executable $tailscale
    if ($ip) {
        return $ip
    }

    Write-LiaisonDependencyStep "Connecting the Tailscale background service"
    Write-Host "Tailscale requires browser authentication. The login page will be opened when available."

    $upResult = Invoke-LiaisonTailscaleCommand `
        -Executable $tailscale `
        -Arguments @("up", "--unattended=true", "--timeout=10s")

    foreach ($line in @($upResult.Output)) {
        Write-Host $line
    }

    $combinedOutput = @($upResult.Output) -join "`n"
    $loginMatch = [regex]::Match($combinedOutput, 'https://login\.tailscale\.com/[^\s"''<>]+')
    if ($loginMatch.Success) {
        $loginUrl = $loginMatch.Value.TrimEnd('.', ',', ';', ')', ']')
        try {
            Start-Process $loginUrl | Out-Null
            Write-Host "Opened the Tailscale login page in the default browser."
        } catch {
            Write-Warning "The Tailscale login page could not be opened automatically: $loginUrl"
        }

        # Give browser authentication time to complete while keeping the installer
        # deterministic. A user can also finish login after Liaison is installed.
        for ($attempt = 0; $attempt -lt 90; $attempt++) {
            Start-Sleep -Seconds 2
            $ip = Get-LiaisonClientTailscaleIPv4 -Executable $tailscale
            if ($ip) {
                Write-Host "Tailscale connection: $ip" -ForegroundColor Green
                return $ip
            }
        }
    }

    Write-Host "LIAISON_TAILSCALE_LOGIN_REQUIRED"
    Write-Warning "Tailscale login is still pending. Liaison Client will still be installed."
    return $null
}

$resolved = Find-LiaisonConnectionFile $ConnectionFile
$connection = $null
if ($resolved) {
    try {
        $connection = Get-Content $resolved -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "The optional connection file could not be read."
        $resolved = $null
    }
}

Add-LiaisonToolPaths | Out-Null
if (-not $SkipDependencyInstall) {
    $needsTailscale = (-not $connection) -or ([string]$connection.transport) -eq "tailscale"
    if ($needsTailscale) {
        $tailscaleIp = Connect-LiaisonClientTailscale -InstallIfMissing
        if (-not $tailscaleIp) {
            Write-Warning "Tailscale login was not completed. Liaison Client will still be installed."
        }
    }
}

$arguments = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", (Join-Path $PSScriptRoot "setup-client.ps1"),
    "-SkipBuild"
)
if ($resolved) {
    $arguments += @("-ConnectionFile", $resolved)
}
if ($NoLaunch) {
    $arguments += "-NoLaunch"
}

& powershell.exe @arguments
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
