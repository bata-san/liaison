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

    return [pscustomobject]@{
        ExitCode = $code
        Output = $output
    }
}

function Get-LiaisonSafeTailscaleIPv4([string]$Executable) {
    $result = Invoke-LiaisonNativeCommand -Executable $Executable -Arguments @("ip", "-4")
    if ($result.ExitCode -ne 0) { return $null }

    foreach ($line in $result.Output) {
        $candidate = ([string]$line).Trim()
        $parsed = $null
        if ([Net.IPAddress]::TryParse($candidate, [ref]$parsed)) {
            $bytes = $parsed.GetAddressBytes()
            if ($bytes.Length -eq 4 -and $bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127) {
                return $candidate
            }
        }
    }
    return $null
}

function Connect-LiaisonTailscale {
    param([switch]$InstallIfMissing)

    Write-LiaisonProgress 58 "Tailscaleを確認" "Tailscale本体とWindowsサービスを確認しています。"
    $tailscale = Get-LiaisonTailscaleExe
    if (-not $tailscale -and $InstallIfMissing) {
        Write-LiaisonProgress 61 "Tailscaleをインストール" "公式MSIを取得してバックグラウンドサービスを導入しています。"
        $tailscale = Install-LiaisonTailscale
    }
    if (-not $tailscale) {
        Write-LiaisonUnifiedLog "LIAISON_TAILSCALE_LOGIN_REQUIRED"
        Write-Warning "Tailscale is not installed. Liaison setup will continue."
        return $null
    }

    Write-LiaisonProgress 64 "Tailscaleサービスを起動" "サービスを自動起動に設定しています。"
    Set-Service -Name Tailscale -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name Tailscale -ErrorAction SilentlyContinue

    $ip = Get-LiaisonSafeTailscaleIPv4 $tailscale
    if ($ip) {
        Write-LiaisonProgress 70 "Tailscale接続完了" "接続用IP $ip を確認しました。"
        return $ip
    }

    Write-LiaisonProgress 66 "Tailscale認証を開始" "ブラウザー認証URLを取得しています。"
    $up = Invoke-LiaisonNativeCommand -Executable $tailscale -Arguments @("up", "--unattended=true", "--timeout=10s")
    $combined = [string]::Join("`n", [string[]]$up.Output)
    $match = [regex]::Match($combined, "https://login\.tailscale\.com/\S+")
    if ($match.Success) {
        $loginUrl = $match.Value.TrimEnd([char[]]".,;)]")
        try {
            Start-Process $loginUrl | Out-Null
            Write-LiaisonProgress 67 "ブラウザーで認証" "開いたTailscale画面でログインしてください。"
        } catch {
            Write-LiaisonUnifiedLog ("WARNING|Tailscale login URL: " + $loginUrl)
        }
    } else {
        Write-LiaisonProgress 67 "Tailscaleログイン待ち" "Tailscaleアプリからログインしてください。"
    }

    for ($attempt = 1; $attempt -le 90; $attempt++) {
        Start-Sleep -Seconds 2
        $ip = Get-LiaisonSafeTailscaleIPv4 $tailscale
        if ($ip) {
            Write-LiaisonProgress 70 "Tailscale接続完了" "接続用IP $ip を確認しました。"
            return $ip
        }
        if (($attempt % 5) -eq 0) {
            $seconds = $attempt * 2
            $percent = 67 + [Math]::Min(2, [Math]::Floor($seconds / 60))
            Write-LiaisonProgress $percent "Tailscaleログイン待ち" "認証を待っています。経過 ${seconds}秒 / 最大180秒"
        }
    }

    Write-LiaisonUnifiedLog "LIAISON_TAILSCALE_LOGIN_REQUIRED"
    Write-LiaisonProgress 70 "Tailscaleログインは後で完了可能" "Liaisonの設定を続行します。"
    Write-Warning "Tailscale login is still pending. Liaison setup will continue."
    return $null
}

$wslDirectPath = Join-Path $PSScriptRoot "wsl-install-direct.ps1"
if (Test-Path -LiteralPath $wslDirectPath -PathType Leaf) {
    . $wslDirectPath
}
