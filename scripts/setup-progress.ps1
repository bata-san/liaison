function Write-LiaisonUnifiedLog([string]$Message) {
    $path = [string]$env:LIAISON_UNIFIED_LOG_PATH
    if (-not $path) {
        return
    }
    try {
        $line = "{0} {1}" -f ([DateTimeOffset]::Now.ToString("o")), $Message
        Add-Content -LiteralPath $path -Value $line -Encoding UTF8
    } catch {
        # Progress logging must never stop setup.
    }
}

function Write-LiaisonProgress(
    [ValidateRange(0, 100)][int]$Percent,
    [string]$Stage,
    [string]$Detail
) {
    Write-LiaisonUnifiedLog ("PROGRESS|{0}|{1}|{2}" -f $Percent, $Stage, $Detail)
}

function Invoke-LiaisonNativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $rawOutput = @()
    $exitCode = -1
    try {
        # Native tools such as `tailscale ip` use stderr for normal states including
        # NeedsLogin. Capture that output without turning it into a terminating error.
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
    foreach ($line in $output) {
        Write-LiaisonUnifiedLog ("COMMAND|{0}|{1}" -f (Split-Path -Leaf $Executable), $line)
    }

    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Output = $output
    }
}

function Get-LiaisonSafeTailscaleIPv4 {
    param([Parameter(Mandatory = $true)][string]$Executable)

    $result = Invoke-LiaisonNativeCommand -Executable $Executable -Arguments @("ip", "-4")
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

function Connect-LiaisonTailscaleInteractive {
    param(
        [switch]$InstallIfMissing,
        [ValidateRange(0, 600)][int]$WaitForLoginSeconds = 180,
        [ValidateRange(0, 100)][int]$ProgressStart = 38,
        [ValidateRange(0, 100)][int]$ProgressEnd = 72
    )

    Write-LiaisonProgress $ProgressStart "Tailscaleを確認" "Tailscale本体とバックグラウンドサービスを確認しています。"
    $tailscale = Get-LiaisonTailscaleExe
    if (-not $tailscale -and $InstallIfMissing) {
        Write-LiaisonProgress ($ProgressStart + 4) "Tailscaleをインストール" "公式MSIを取得してバックグラウンドサービスを導入しています。"
        $tailscale = Install-LiaisonTailscale
    }
    if (-not $tailscale) {
        Write-LiaisonUnifiedLog "LIAISON_TAILSCALE_LOGIN_REQUIRED"
        Write-Warning "Tailscale is not installed. Liaison installation will continue."
        return $null
    }

    Write-LiaisonProgress ($ProgressStart + 8) "Tailscaleサービスを起動" "Windowsサービスを自動起動に設定しています。"
    Set-Service -Name Tailscale -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name Tailscale -ErrorAction SilentlyContinue

    $ip = Get-LiaisonSafeTailscaleIPv4 -Executable $tailscale
    if ($ip) {
        Write-LiaisonProgress $ProgressEnd "Tailscale接続完了" "接続用IP $ip を確認しました。"
        return $ip
    }

    Write-LiaisonProgress ($ProgressStart + 14) "Tailscale認証を開始" "ブラウザー認証URLを取得しています。"
    $upResult = Invoke-LiaisonNativeCommand `
        -Executable $tailscale `
        -Arguments @("up", "--unattended=true", "--timeout=10s")

    $combinedOutput = @($upResult.Output) -join "`n"
    $loginMatch = [regex]::Match($combinedOutput, 'https://login\.tailscale\.com/[^\s"''<>]+')
    if ($loginMatch.Success) {
        $loginUrl = $loginMatch.Value.TrimEnd('.', ',', ';', ')', ']')
        Write-LiaisonUnifiedLog "Tailscale browser login URL received."
        try {
            Start-Process $loginUrl | Out-Null
            Write-LiaisonProgress ($ProgressStart + 18) "ブラウザーで認証" "開いたTailscale画面でログインを完了してください。"
        } catch {
            Write-LiaisonUnifiedLog ("WARNING|Tailscale login page could not be opened automatically: " + $loginUrl)
        }
    } else {
        Write-LiaisonProgress ($ProgressStart + 18) "Tailscaleログイン待ち" "Tailscaleアプリからログインしてください。"
    }

    if ($WaitForLoginSeconds -gt 0) {
        $attempts = [Math]::Max(1, [Math]::Ceiling($WaitForLoginSeconds / 2.0))
        for ($attempt = 0; $attempt -lt $attempts; $attempt++) {
            Start-Sleep -Seconds 2
            $ip = Get-LiaisonSafeTailscaleIPv4 -Executable $tailscale
            if ($ip) {
                Write-LiaisonProgress $ProgressEnd "Tailscale接続完了" "接続用IP $ip を確認しました。"
                return $ip
            }

            if (($attempt % 5) -eq 4) {
                $elapsed = [Math]::Min($WaitForLoginSeconds, ($attempt + 1) * 2)
                $span = [Math]::Max(1, $ProgressEnd - ($ProgressStart + 18))
                $fraction = [Math]::Min(1.0, $elapsed / [double]$WaitForLoginSeconds)
                $percent = [Math]::Min($ProgressEnd - 1, ($ProgressStart + 18) + [Math]::Floor($span * $fraction))
                Write-LiaisonProgress $percent "Tailscaleログイン待ち" "ブラウザー認証を待っています。経過 ${elapsed}秒 / 最大 ${WaitForLoginSeconds}秒"
            }
        }
    }

    Write-LiaisonUnifiedLog "LIAISON_TAILSCALE_LOGIN_REQUIRED"
    Write-LiaisonProgress $ProgressEnd "Tailscaleログインは後で完了可能" "Liaisonのインストールを続行します。"
    Write-Warning "Tailscale login is still pending. Liaison installation will continue."
    return $null
}

foreach ($wslHelperName in @("wsl-install-fallback.ps1", "wsl-install-direct.ps1")) {
    $wslHelperPath = Join-Path $PSScriptRoot $wslHelperName
    if (Test-Path -LiteralPath $wslHelperPath -PathType Leaf) {
        . $wslHelperPath
    }
}
