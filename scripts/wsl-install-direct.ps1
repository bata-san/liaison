function Get-LiaisonWslDistributions {
    $names = @()
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $raw = @(& "$env:SystemRoot\System32\wsl.exe" --list --quiet 2>$null)
        $code = $LASTEXITCODE
    } catch {
        $raw = @()
        $code = -1
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    if ($code -eq 0) {
        foreach ($item in $raw) {
            $name = (([string]$item) -replace "\x00", "").Trim()
            if ($name) { $names += $name }
        }
    }
    $registryRoot = "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Lxss"
    if (Test-Path -LiteralPath $registryRoot) {
        foreach ($key in Get-ChildItem -LiteralPath $registryRoot -ErrorAction SilentlyContinue) {
            try {
                $name = (Get-ItemProperty -LiteralPath $key.PSPath -Name DistributionName -ErrorAction Stop).DistributionName
                if ($name) { $names += ([string]$name).Trim() }
            } catch {
            }
        }
    }
    return @($names | Where-Object { $_ } | Sort-Object -Unique)
}

function Invoke-LiaisonWslCommand {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    Write-LiaisonUnifiedLog ("WSL command: wsl.exe " + ($Arguments -join " "))
    $oldPreference = $ErrorActionPreference
    $raw = @()
    $code = -1
    try {
        $ErrorActionPreference = "Continue"
        $raw = @(& "$env:SystemRoot\System32\wsl.exe" @Arguments 2>&1)
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
            Write-LiaisonUnifiedLog ("WSL|" + $line)
        }
    }
    Write-LiaisonUnifiedLog ("WSL exit code: " + $code)
    return [pscustomobject]@{ ExitCode = $code; Output = $output }
}

function Get-LiaisonWslDetail($Result) {
    $tail = @($Result.Output | Select-Object -Last 12)
    if ($tail.Count -eq 0) { return "WSL returned no diagnostic output." }
    return ($tail -join " | ")
}

function Invoke-LiaisonUbuntuDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $folder = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $partial = $Destination + ".partial"
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    $bitsAvailable = $false
    try {
        Import-Module BitsTransfer -ErrorAction Stop
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) { $bitsAvailable = $true }
    } catch {
        $bitsAvailable = $false
    }
    if ($bitsAvailable) {
        $job = $null
        try {
            $job = Start-BitsTransfer -Source $Uri -Destination $partial -Asynchronous -DisplayName "Liaison Ubuntu WSL" -ErrorAction Stop
            while ($true) {
                $job = Get-BitsTransfer -Id $job.Id -ErrorAction Stop
                if ($job.JobState -eq "Transferred") {
                    Complete-BitsTransfer -BitsJob $job -ErrorAction Stop
                    break
                }
                if ($job.JobState -eq "Error" -or $job.JobState -eq "Cancelled") {
                    throw ("BITS download failed: " + $job.ErrorDescription)
                }
                if ($job.BytesTotal -gt 0) {
                    $downloadPercent = [Math]::Floor(($job.BytesTransferred * 100.0) / $job.BytesTotal)
                    $overall = 28 + [Math]::Floor($downloadPercent * 0.10)
                    $received = [Math]::Round($job.BytesTransferred / 1MB, 1)
                    $total = [Math]::Round($job.BytesTotal / 1MB, 1)
                    $detail = $downloadPercent.ToString() + "% - " + $received.ToString() + " MB / " + $total.ToString() + " MB"
                    Write-LiaisonProgress $overall "Ubuntuをダウンロード中" $detail
                }
                Start-Sleep -Seconds 2
            }
        } catch {
            if ($job) { Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            Write-LiaisonUnifiedLog ("WARNING|BITS download failed: " + $_.Exception.Message)
            Write-LiaisonProgress 28 "Ubuntuをダウンロード中" "別のHTTPS方式へ切り替えています。操作は不要です。"
            Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $partial -ErrorAction Stop
        }
    } else {
        Write-LiaisonProgress 28 "Ubuntuをダウンロード中" "公式イメージをHTTPSで取得しています。操作は不要です。"
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $partial -ErrorAction Stop
    }
    Move-Item -LiteralPath $partial -Destination $Destination -Force
}

function Get-LiaisonExpectedChecksum {
    param(
        [Parameter(Mandatory = $true)][string]$ChecksumUri,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$DownloadFolder
    )

    New-Item -ItemType Directory -Force -Path $DownloadFolder | Out-Null
    $checksumPath = Join-Path $DownloadFolder "SHA256SUMS"
    $checksumPartial = $checksumPath + ".partial"
    Remove-Item -LiteralPath $checksumPartial -Force -ErrorAction SilentlyContinue

    Invoke-WebRequest -UseBasicParsing -Uri $ChecksumUri -OutFile $checksumPartial -ErrorAction Stop
    Move-Item -LiteralPath $checksumPartial -Destination $checksumPath -Force

    $bytes = [IO.File]::ReadAllBytes($checksumPath)
    if ($bytes.Length -eq 0) {
        throw "Ubuntuのチェックサム一覧が空でした。ネットワークまたはプロキシ設定を確認してください。"
    }

    $checksumText = [Text.Encoding]::UTF8.GetString($bytes) -replace "\x00", ""
    $pattern = "(?im)^([0-9a-f]{64})\s+\*?" + [regex]::Escape($FileName) + "\s*$"
    $match = [regex]::Match($checksumText, $pattern)
    if (-not $match.Success) {
        $preview = (($checksumText -split "`r?`n") | Select-Object -First 4) -join " | "
        Write-LiaisonUnifiedLog ("Checksum list preview: " + $preview)
        throw ("Ubuntuの公式チェックサム一覧を解析できませんでした。対象: " + $FileName)
    }

    return $match.Groups[1].Value.ToLowerInvariant()
}

function Ensure-LiaisonWslDistribution {
    param([Parameter(Mandatory = $true)][string]$Distribution)
    if ((Get-LiaisonWslDistributions) -contains $Distribution) {
        Write-LiaisonUnifiedLog ("WSL distribution already installed: " + $Distribution)
        Write-LiaisonProgress 43 "Ubuntuは準備済み" "既存のUbuntuを使用します。"
        return
    }

    $fileName = "ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz"
    $baseUri = "https://cloud-images.ubuntu.com/wsl/releases/noble/current"
    $archiveUri = $baseUri + "/" + $fileName
    $checksumUri = $baseUri + "/SHA256SUMS"
    $downloadFolder = Join-Path $env:ProgramData "Liaison\downloads"
    $archivePath = Join-Path $downloadFolder $fileName

    Write-LiaisonProgress 26 "Ubuntuを準備中" "Microsoft Storeを使わず、Ubuntu 24.04 LTSの公式イメージを使用します。"
    Write-LiaisonProgress 27 "安全性を確認中" "公式SHA-256チェックサムを取得しています。操作は不要です。"
    $expected = Get-LiaisonExpectedChecksum -ChecksumUri $checksumUri -FileName $fileName -DownloadFolder $downloadFolder
    Write-LiaisonUnifiedLog ("Expected Ubuntu SHA-256: " + $expected)

    $verified = $false
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $needDownload = -not (Test-Path -LiteralPath $archivePath -PathType Leaf)
        if (-not $needDownload -and (Get-Item -LiteralPath $archivePath).Length -lt 100MB) {
            Write-LiaisonUnifiedLog "WARNING|Cached Ubuntu image is incomplete and will be replaced."
            Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
            $needDownload = $true
        }

        if ($needDownload) {
            Invoke-LiaisonUbuntuDownload -Uri $archiveUri -Destination $archivePath
        } else {
            Write-LiaisonProgress 38 "Ubuntuを確認中" "保存済みの公式イメージを検証しています。"
            Write-LiaisonUnifiedLog ("Using cached Ubuntu image: " + $archivePath)
        }

        Write-LiaisonProgress 39 "Ubuntuを検証中" "ダウンロード内容が公式ハッシュと一致するか確認しています。"
        $actual = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-LiaisonUnifiedLog ("Actual Ubuntu SHA-256: " + $actual)
        if ($actual -eq $expected) {
            $verified = $true
            break
        }

        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        if ($attempt -lt 2) {
            Write-LiaisonUnifiedLog "WARNING|Ubuntu image checksum mismatch. Downloading a clean copy."
            Write-LiaisonProgress 28 "Ubuntuを再取得中" "保存済みファイルが不完全だったため、自動で取得し直しています。"
        }
    }

    if (-not $verified) {
        throw "Ubuntu公式イメージのSHA-256検証に2回失敗しました。プロキシやセキュリティソフトがダウンロードを変更していないか確認してください。"
    }
    Write-LiaisonUnifiedLog ("Ubuntu SHA-256 verified: " + $actual)

    $installLocation = Join-Path $env:LOCALAPPDATA ("Liaison\WSL\" + $Distribution)
    if (Test-Path -LiteralPath $installLocation) {
        Remove-Item -LiteralPath $installLocation -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path $installLocation | Out-Null

    Write-LiaisonProgress 40 "Ubuntuを登録中" "検証済みイメージをWSL 2へ登録しています。操作は不要です。"
    $importResult = Invoke-LiaisonWslCommand -Arguments @("--import", $Distribution, $installLocation, $archivePath, "--version", "2")
    if ($importResult.ExitCode -ne 0) {
        throw ("Ubuntu import failed with exit code " + $importResult.ExitCode + ". " + (Get-LiaisonWslDetail $importResult))
    }

    Write-LiaisonProgress 42 "Ubuntuを初期化中" "Ubuntuを初めて起動して動作を確認しています。"
    $initResult = Invoke-LiaisonWslCommand -Arguments @("-d", $Distribution, "-u", "root", "--exec", "sh", "-lc", "true")
    if ($initResult.ExitCode -ne 0) {
        throw ("Ubuntu was imported but could not start. Windows may need a restart. " + (Get-LiaisonWslDetail $initResult))
    }
    Write-LiaisonProgress 43 "Ubuntuの準備完了" "Ubuntu WSLが正常に起動しました。"
}
