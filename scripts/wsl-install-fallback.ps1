function Write-LiaisonWslInstallLog([string]$Message) {
    if (Get-Command Write-LiaisonUnifiedLog -ErrorAction SilentlyContinue) {
        Write-LiaisonUnifiedLog $Message
        return
    }

    $path = [string]$env:LIAISON_UNIFIED_LOG_PATH
    if (-not $path) {
        return
    }
    try {
        $line = "{0} {1}" -f ([DateTimeOffset]::Now.ToString("o")), $Message
        Add-Content -LiteralPath $path -Value $line -Encoding UTF8
    } catch {
        # WSL diagnostics must never stop setup.
    }
}

function Write-LiaisonWslInstallProgress(
    [ValidateRange(0, 100)][int]$Percent,
    [string]$Stage,
    [string]$Detail
) {
    if (Get-Command Write-LiaisonProgress -ErrorAction SilentlyContinue) {
        Write-LiaisonProgress $Percent $Stage $Detail
    } else {
        Write-LiaisonWslInstallLog ("PROGRESS|{0}|{1}|{2}" -f $Percent, $Stage, $Detail)
    }
}

function ConvertTo-LiaisonWslOutput([object[]]$Items) {
    return @(
        $Items |
            ForEach-Object { (([string]$_) -replace "\x00", "").Trim() } |
            Where-Object { $_ }
    )
}

function Get-LiaisonWslDistributions {
    $names = @()
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $raw = & "$env:SystemRoot\System32\wsl.exe" --list --quiet 2>$null
        $exitCode = $LASTEXITCODE
    } catch {
        $raw = @()
        $exitCode = -1
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -eq 0) {
        $names += ConvertTo-LiaisonWslOutput @($raw)
    }

    $registryRoot = "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Lxss"
    if (Test-Path -LiteralPath $registryRoot) {
        $names += @(
            Get-ChildItem -LiteralPath $registryRoot -ErrorAction SilentlyContinue |
                ForEach-Object {
                    try {
                        $name = (Get-ItemProperty -LiteralPath $_.PSPath -Name DistributionName -ErrorAction Stop).DistributionName
                        if ($name) { ([string]$name).Trim() }
                    } catch {
                        # Ignore incomplete WSL registrations.
                    }
                }
        )
    }

    return @($names | Where-Object { $_ } | Sort-Object -Unique)
}

function Invoke-LiaisonWslInstall {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    Write-LiaisonWslInstallLog ("WSL command: wsl.exe " + ($Arguments -join " "))
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $rawOutput = @(& "$env:SystemRoot\System32\wsl.exe" @Arguments 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { -1 } else { [int]$LASTEXITCODE }
    } catch {
        $rawOutput = @($_.Exception.Message)
        $exitCode = -1
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $output = ConvertTo-LiaisonWslOutput $rawOutput
    foreach ($line in $output) {
        Write-Host $line
        Write-LiaisonWslInstallLog ("WSL | " + $line)
    }
    Write-LiaisonWslInstallLog ("WSL command exit code: $exitCode")

    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Output = $output
    }
}

function Get-LiaisonWslFailureDetail([object]$Result) {
    $tail = @($Result.Output | Select-Object -Last 12)
    if ($tail.Count -eq 0) {
        return "WSL returned no diagnostic output."
    }
    return ($tail -join " | ")
}

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

    $handler = New-Object System.Net.Http.HttpClientHandler
    $client = New-Object System.Net.Http.HttpClient($handler)
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
        $total = [int64]($response.Content.Headers.ContentLength | Select-Object -First 1)
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

function Install-LiaisonUbuntuByImport {
    param([Parameter(Mandatory = $true)][string]$Distribution)

    if (-not [Environment]::Is64BitOperatingSystem) {
        throw "The automatic Ubuntu fallback currently requires 64-bit Windows."
    }

    $fileName = "ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz"
    $baseUri = "https://cloud-images.ubuntu.com/wsl/releases/noble/current"
    $archiveUri = "$baseUri/$fileName"
    $checksumUri = "$baseUri/SHA256SUMS"
    $downloadDirectory = Join-Path $env:ProgramData "Liaison\downloads"
    $archivePath = Join-Path $downloadDirectory $fileName

    Write-LiaisonWslInstallProgress 27 "Ubuntu公式イメージを準備" "Microsoft Storeを使わず、Ubuntu 24.04 LTSの公式WSLイメージを取得します。"
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or (Get-Item -LiteralPath $archivePath).Length -lt 100MB) {
        Invoke-LiaisonDownloadWithProgress `
            -Uri $archiveUri `
            -Destination $archivePath `
            -ProgressStart 28 `
            -ProgressEnd 38
    } else {
        Write-LiaisonWslInstallLog "Using cached Ubuntu WSL archive: $archivePath"
    }

    Write-LiaisonWslInstallProgress 39 "Ubuntuイメージを検証" "公式SHA-256とダウンロードしたファイルを照合しています。"
    $checksumText = (Invoke-WebRequest -UseBasicParsing -Uri $checksumUri).Content
    $match = [regex]::Match(
        [string]$checksumText,
        "(?im)^([a-f0-9]{64})\s+\*?" + [regex]::Escape($fileName) + "\s*$"
    )
    if (-not $match.Success) {
        throw "The official Ubuntu checksum file did not contain $fileName."
    }
    $expectedHash = $match.Groups[1].Value.ToLowerInvariant()
    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        throw "The downloaded Ubuntu WSL image failed SHA-256 verification."
    }
    Write-LiaisonWslInstallLog "Ubuntu WSL image SHA-256 verified: $actualHash"

    $installLocation = Join-Path $env:LOCALAPPDATA ("Liaison\WSL\" + $Distribution)
    New-Item -ItemType Directory -Force -Path $installLocation | Out-Null
    Write-LiaisonWslInstallProgress 40 "Ubuntuを展開" "公式イメージをWSL 2ディストリビューションとして登録しています。"
    $result = Invoke-LiaisonWslInstall -Arguments @(
        "--import",
        $Distribution,
        $installLocation,
        $archivePath,
        "--version",
        "2"
    )
    if ($result.ExitCode -ne 0) {
        $detail = Get-LiaisonWslFailureDetail $result
        throw "Ubuntu import failed with exit code $($result.ExitCode). $detail"
    }
}

function Ensure-LiaisonWslDistribution {
    param([Parameter(Mandatory = $true)][string]$Distribution)

    if ((Get-LiaisonWslDistributions) -contains $Distribution) {
        Write-LiaisonWslInstallLog "WSL distribution already installed: $Distribution"
        return
    }

    Write-LiaisonDependencyStep "Installing the $Distribution WSL distribution"
    Write-LiaisonWslInstallProgress 26 "Ubuntuをインストール" "WSLのオンライン配布からUbuntuを取得しています。"
    $webResult = Invoke-LiaisonWslInstall -Arguments @(
        "--install", "--web-download", "--no-launch", "-d", $Distribution
    )

    if ($webResult.ExitCode -ne 0 -and (Get-LiaisonWslDistributions) -notcontains $Distribution) {
        $webDetail = Get-LiaisonWslFailureDetail $webResult
        Write-LiaisonWslInstallLog ("WARNING|WSL web-download installation failed. " + $webDetail)
        Write-LiaisonWslInstallProgress 27 "Ubuntuの代替導入へ切替" "WSLのオンライン導入に失敗したため、Ubuntu公式イメージを直接使用します。"
        Install-LiaisonUbuntuByImport -Distribution $Distribution
    }

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
        $detail = Get-LiaisonWslFailureDetail $webResult
        throw "The $Distribution WSL distribution was not registered. Last WSL output: $detail"
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
