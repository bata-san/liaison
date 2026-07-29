function Write-LiaisonUnifiedLog([string]$Message) {
    $path = [string]$env:LIAISON_UNIFIED_LOG_PATH
    if (-not $path) { return }
    try {
        $line = "{0} {1}" -f ([DateTimeOffset]::Now.ToString("o")), $Message
        Add-Content -LiteralPath $path -Value $line -Encoding UTF8
    } catch {
    }
}

function Write-LiaisonProgress([int]$Percent, [string]$Stage, [string]$Detail) {
    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    Write-LiaisonUnifiedLog ("PROGRESS|{0}|{1}|{2}" -f $Percent, $Stage, $Detail)
}

function Invoke-LiaisonNativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $oldPreference = $ErrorActionPreference
    $raw = @()
    $code = -1
    try {
        $ErrorActionPreference = "Continue"
        $raw = @(& $Executable @Arguments 2>&1)
        if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
    } catch {
        $raw = @($_.Exception.Message)
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    $output = @()
    foreach ($item in $raw) {
        $line = (([string]$item) -replace "\x00", "").Trim()
        if ($line) {
            $output += $line
            Write-LiaisonUnifiedLog ("COMMAND|{0}|{1}" -f (Split-Path -Leaf $Executable), $line)
        }
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $output }
}

function Get-LiaisonSafeTailscaleIPv4([string]$Executable) {
    $result = Invoke-LiaisonNativeCommand -Executable $Executable -Arguments @("ip", "-4")
    if ($result.ExitCode -ne 0) { return $null }
    foreach ($line in $result.Output) {
        $candidate = ([string]$line).Trim()
        $parsed = $null
        if ([Net.IPAddress]::TryParse($candidate, [ref]$parsed)) {
            $bytes = $parsed.GetAddressBytes()
            if ($bytes.Length -eq 4 -and $bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127) { return $candidate }
        }
    }
    return $null
}

function Connect-LiaisonTailscale {
    param([switch]$InstallIfMissing)
    Write-LiaisonProgress 58 "Tailscale check" "Checking the Tailscale executable and Windows service."
    $tailscale = Get-LiaisonTailscaleExe
    if (-not $tailscale -and $InstallIfMissing) {
        Write-LiaisonProgress 61 "Tailscale install" "Downloading and installing the official Tailscale MSI."
        $tailscale = Install-LiaisonTailscale
    }
    if (-not $tailscale) {
        Write-LiaisonUnifiedLog "LIAISON_TAILSCALE_LOGIN_REQUIRED"
        Write-Warning "Tailscale is not installed. Liaison setup will continue."
        return $null
    }
    Write-LiaisonProgress 64 "Tailscale service" "Starting the Tailscale Windows service."
    Set-Service -Name Tailscale -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name Tailscale -ErrorAction SilentlyContinue
    $ip = Get-LiaisonSafeTailscaleIPv4 $tailscale
    if ($ip) {
        Write-LiaisonProgress 70 "Tailscale ready" ("Tailscale IP: " + $ip)
        return $ip
    }
    Write-LiaisonProgress 66 "Tailscale authentication" "Requesting browser authentication."
    $up = Invoke-LiaisonNativeCommand -Executable $tailscale -Arguments @("up", "--unattended=true", "--timeout=10s")
    $combined = [string]::Join("`n", [string[]]$up.Output)
    $match = [regex]::Match($combined, "https://login\.tailscale\.com/\S+")
    if ($match.Success) {
        $loginUrl = $match.Value
        try {
            Start-Process $loginUrl | Out-Null
            Write-LiaisonProgress 67 "Tailscale browser login" "Complete login in the browser window."
        } catch {
            Write-LiaisonUnifiedLog ("WARNING|Tailscale login address: " + $loginUrl)
        }
    } else {
        Write-LiaisonProgress 67 "Tailscale login pending" "Open the Tailscale app and complete login."
    }
    for ($attempt = 1; $attempt -le 90; $attempt++) {
        Start-Sleep -Seconds 2
        $ip = Get-LiaisonSafeTailscaleIPv4 $tailscale
        if ($ip) {
            Write-LiaisonProgress 70 "Tailscale ready" ("Tailscale IP: " + $ip)
            return $ip
        }
        if (($attempt % 5) -eq 0) {
            $seconds = $attempt * 2
            Write-LiaisonProgress 68 "Tailscale login pending" ("Waiting for login: " + $seconds + " / 180 seconds")
        }
    }
    Write-LiaisonUnifiedLog "LIAISON_TAILSCALE_LOGIN_REQUIRED"
    Write-LiaisonProgress 70 "Tailscale login deferred" "Liaison setup will continue without a current Tailscale IP."
    Write-Warning "Tailscale login is still pending. Liaison setup will continue."
    return $null
}

$wslDirectPath = Join-Path $PSScriptRoot "wsl-install-direct.ps1"
if (Test-Path -LiteralPath $wslDirectPath -PathType Leaf) { . $wslDirectPath }
