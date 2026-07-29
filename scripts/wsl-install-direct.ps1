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

    return [pscustomobject]@{
        ExitCode = $code
        Output = $output
    }
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
                    Write-LiaisonProgress $overall "Ubuntuをダウンロード" "${downloadPercent}% - ${received} MB / ${total} MB"
                }
                Start-Sleep -Seconds 2
            }
        } catch {
            if ($job) {
                Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            Write-LiaisonUnifiedLog ("WARNING|BITS download failed: " + $_.Exception.Message)
            Write-LiaisonProgress 28 "Ubuntuをダウンロード" "通常のHTTPSダウンロードへ切り替えました。"
            Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $partial -ErrorAction Stop
        }
    } else {
        Write-LiaisonProgress 28 "Ubuntuをダウンロード" "公式イメージをHTTPSで取得しています。"
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $partial -ErrorAction Stop
    }

    Move-Item -LiteralPath $partial -Destination $Destination -Force
}

function Ensure-LiaisonWslDistribution {
    param([Parameter(Mandatory = $true)][string]$Distribution)

    if ((Get-LiaisonWslDistributions) -contains $Distribution) {
        Write-LiaisonUnifiedLog ("WSL distribution already installed: " + $Distribution)
        return
    }

    $fileName = "ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz"
    $baseUri = "https://cloud-images.ubuntu.com/wsl/releases/noble/current"
    $archiveUri = $baseUri + "/" + $fileName
    $checksumUri = $baseUri + "/SHA256SUMS"
    $downloadFolder = Join-Path $env:ProgramData "Liaison\downloads"
    $archivePath = Join-Path $downloadFolder $fileName

    Write-LiaisonProgress 26 "Ubuntu公式イメージを準備" "Microsoft Storeを使わずUbuntu 24.04 LTSを直接導入します。"
    $needDownload = $true
    if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
        if ((Get-Item -LiteralPath $archivePath).Length -gt 100MB) { $needDownload = $false }
    }
    if ($needDownload) {
        Invoke-LiaisonUbuntuDownload -Uri $archiveUri -Destination $archivePath
    } else {
        Write-LiaisonUnifiedLog ("Using cached Ubuntu image: " + $archivePath)
    }

    Write-LiaisonProgress 39 "Ubuntuイメージを検証" "公式SHA-256とダウンロード済みファイルを照合しています。"
    $checksumText = (Invoke-WebRequest -UseBasicParsing -Uri $checksumUri -ErrorAction Stop).Content
    $pattern = "(?im)^([a-f0-9]{64})\s+\*?" + [regex]::Escape($fileName) + "\s*$"
    $match = [regex]::Match([string]$checksumText, $pattern)
    if (-not $match.Success) {
        throw ("The Ubuntu checksum file did not contain " + $fileName + ".")
    }
    $expected = $match.Groups[1].Value.ToLowerInvariant()
    $actual = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        throw "The downloaded Ubuntu image failed SHA-256 verification."
    }
    Write-LiaisonUnifiedLog ("Ubuntu SHA-256 verified: " + $actual)

    $installLocation = Join-Path $env:LOCALAPPDATA ("Liaison\WSL\" + $Distribution)
    New-Item -ItemType Directory -Force -Path $installLocation | Out-Null
    Write-LiaisonProgress 40 "Ubuntuを展開" "公式イメージをWSL 2ディストリビューションとして登録しています。"
    $import = Invoke-LiaisonWslCommand -Arguments @("--import", $Distribution, $installLocation, $archivePath, "--version", "2")
    if ($import.ExitCode -ne 0) {
        throw ("Ubuntu import failed with exit code " + $import.ExitCode + ". " + (Get-LiaisonWslDetail $import))
    }

    Write-LiaisonProgress 42 "Ubuntuを初期化" "Ubuntuをrootユーザーで初回起動しています。"
    $initialize = Invoke-LiaisonWslCommand -Arguments @("-d", $Distribution, "-u", "root", "--exec", "sh", "-lc", "true")
    if ($initialize.ExitCode -ne 0) {
        $detail = Get-LiaisonWslDetail $initialize
        throw ("Ubuntu was imported but could not start. Windows may need a restart. " + $detail)
    }

    Write-LiaisonProgress 43 "Ubuntu準備完了" "Ubuntu WSLディストリビューションを初期化しました。"
}
