# Final WSL overrides for the unified installer. These definitions are loaded after
# bootstrap-dependencies.ps1 and wsl-install-fallback.ps1.

function Invoke-LiaisonDownloadWithProgress {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination,
        [ValidateRange(0, 100)][int]$ProgressStart = 27,
        [ValidateRange(0, 100)][int]$ProgressEnd = 38
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Add-Type -AssemblyName System.Net.Http

    $directory = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporary = $Destination + ".partial"
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(45)
    $response = $null
    $input = $null
    $output = $null
    try {
        $response = $client.GetAsync(
            $Uri,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()
        $response.EnsureSuccessStatusCode()
        $totalValue = $response.Content.Headers.ContentLength
        $total = if ($null -eq $totalValue) { [int64]0 } else { [int64]$totalValue }
        $input = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $output = [IO.File]::Open($temporary, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] (1024 * 1024)
        $downloaded = [int64]0
        $lastLoggedPercent = -1
        $lastLoggedAt = [DateTimeOffset]::Now

        while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $output.Write($buffer, 0, $read)
            $downloaded += $read
            $now = [DateTimeOffset]::Now
            $shouldLog = ($now - $lastLoggedAt).TotalSeconds -ge 2

            if ($total -gt 0) {
                $downloadPercent = [Math]::Min(100, [Math]::Floor(($downloaded * 100.0) / $total))
                if ($downloadPercent -ne $lastLoggedPercent -and $shouldLog) {
                    $span = [Math]::Max(1, $ProgressEnd - $ProgressStart)
                    $overall = [Math]::Min($ProgressEnd, $ProgressStart + [Math]::Floor($span * ($downloadPercent / 100.0)))
                    $downloadedMb = [Math]::Round($downloaded / 1MB, 1)
                    $totalMb = [Math]::Round($total / 1MB, 1)
                    Write-LiaisonWslInstallProgress $overall "Ubuntuをダウンロード" "${downloadPercent}% — ${downloadedMb} MB / ${totalMb} MB"
                    $lastLoggedPercent = $downloadPercent
                    $lastLoggedAt = $now
                }
            } elseif ($shouldLog) {
                $downloadedMb = [Math]::Round($downloaded / 1MB, 1)
                Write-LiaisonWslInstallProgress $ProgressStart "Ubuntuをダウンロード" "${downloadedMb} MBを受信しました。"
                $lastLoggedAt = $now
            }
        }
        $output.Flush()
    } finally {
        if ($output) { $output.Dispose() }
        if ($input) { $input.Dispose() }
        if ($response) { $response.Dispose() }
        $client.Dispose()
        $handler.Dispose()
    }

    Move-Item -LiteralPath $temporary -Destination $Destination -Force
}

function Ensure-LiaisonWslDistribution {
    param([Parameter(Mandatory = $true)][string]$Distribution)

    if ((Get-LiaisonWslDistributions) -contains $Distribution) {
        Write-LiaisonWslInstallLog "WSL distribution already installed: $Distribution"
        return
    }

    Write-LiaisonDependencyStep "Installing the $Distribution WSL distribution"
    Write-LiaisonWslInstallProgress 26 "Ubuntu公式イメージを使用" "Microsoft Storeを経由せず、Ubuntu 24.04 LTSを直接導入します。"
    Install-LiaisonUbuntuByImport -Distribution $Distribution

    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        if ((Get-LiaisonWslDistributions) -contains $Distribution) {
            break
        }
        Start-Sleep -Seconds 1
        if (($attempt % 5) -eq 4) {
            Write-LiaisonWslInstallProgress 41 "Ubuntuの登録を確認" "WSLディストリビューション一覧への反映を待っています。経過 $($attempt + 1)秒"
        }
    }
    if ((Get-LiaisonWslDistributions) -notcontains $Distribution) {
        throw "The $Distribution WSL distribution was imported but was not registered in the current Windows user profile."
    }

    Write-LiaisonWslInstallProgress 42 "Ubuntuを初期化" "Ubuntuをrootユーザーで初回起動しています。"
    $initResult = Invoke-LiaisonWslInstall -Arguments @(
        "-d", $Distribution, "-u", "root", "--exec", "sh", "-lc", "true"
    )
    if ($initResult.ExitCode -ne 0) {
        $detail = Get-LiaisonWslFailureDetail $initResult
        $lower = $detail.ToLowerInvariant()
        if ($lower.Contains("restart") -or $lower.Contains("再起動") -or $lower.Contains("hcs_e_hyperv_not_installed")) {
            throw "Ubuntu was installed, but Windows must be restarted before WSL 2 can start. $detail"
        }
        throw "Ubuntu was installed but could not be initialized (exit code $($initResult.ExitCode)). $detail"
    }

    Write-LiaisonWslInstallProgress 43 "Ubuntu準備完了" "Ubuntu WSLディストリビューションを初期化しました。"
}
