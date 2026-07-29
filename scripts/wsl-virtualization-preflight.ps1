# WSL 2 virtualization preflight and native output decoding.
# Keep this file ASCII-only so Windows PowerShell 5.1 can parse it without a BOM.

function ConvertTo-LiaisonNativeArgument([string]$Value) {
    if ($null -eq $Value) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function ConvertFrom-LiaisonNativeBytes([byte[]]$Bytes) {
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return "" }

    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        return [Text.Encoding]::BigEndianUnicode.GetString($Bytes, 2, $Bytes.Length - 2)
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [Text.Encoding]::UTF8.GetString($Bytes, 3, $Bytes.Length - 3)
    }

    $sampleLength = [Math]::Min($Bytes.Length, 512)
    $oddNulls = 0
    $evenNulls = 0
    for ($index = 0; $index -lt $sampleLength; $index++) {
        if ($Bytes[$index] -eq 0) {
            if (($index % 2) -eq 0) { $evenNulls++ } else { $oddNulls++ }
        }
    }
    $pairCount = [Math]::Max(1, [Math]::Floor($sampleLength / 2))
    if ($oddNulls -gt ($pairCount * 0.20)) {
        return [Text.Encoding]::Unicode.GetString($Bytes)
    }
    if ($evenNulls -gt ($pairCount * 0.20)) {
        return [Text.Encoding]::BigEndianUnicode.GetString($Bytes)
    }

    $utf8 = [Text.UTF8Encoding]::new($false, $false).GetString($Bytes)
    if ($utf8 -notmatch "\uFFFD") { return $utf8 }
    return [Text.Encoding]::Default.GetString($Bytes)
}

function Invoke-LiaisonWslCommand {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 1200
    )

    $stdoutPath = Join-Path $env:TEMP ("LiaisonWsl-{0}.stdout.bin" -f ([Guid]::NewGuid().ToString("N")))
    $stderrPath = Join-Path $env:TEMP ("LiaisonWsl-{0}.stderr.bin" -f ([Guid]::NewGuid().ToString("N")))
    $argumentLine = ($Arguments | ForEach-Object { ConvertTo-LiaisonNativeArgument ([string]$_) }) -join " "
    $startedAt = [DateTimeOffset]::Now
    $exitCode = -1
    $timedOut = $false

    Write-LiaisonUnifiedLog ("WSL command: wsl.exe " + $argumentLine)
    try {
        $process = Start-Process `
            -FilePath "$env:SystemRoot\System32\wsl.exe" `
            -ArgumentList $argumentLine `
            -WindowStyle Hidden `
            -PassThru `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath

        while (-not $process.HasExited) {
            if (([DateTimeOffset]::Now - $startedAt).TotalSeconds -ge $TimeoutSeconds) {
                try { $process.Kill() } catch { }
                $timedOut = $true
                break
            }
            Start-Sleep -Milliseconds 350
            $process.Refresh()
        }
        $process.WaitForExit()
        $process.Refresh()
        if (-not $timedOut -and $null -ne $process.ExitCode) {
            $exitCode = [int]$process.ExitCode
        } elseif ($timedOut) {
            $exitCode = 1460
        }
    } catch {
        Write-LiaisonUnifiedLog ("WARNING|WSL process launch failed: " + $_.Exception.Message)
    }

    $output = New-Object Collections.Generic.List[string]
    foreach ($path in @($stdoutPath, $stderrPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            $text = ConvertFrom-LiaisonNativeBytes ([IO.File]::ReadAllBytes($path))
            foreach ($line in @($text -split "`r?`n")) {
                $clean = (([string]$line) -replace "\x00", "").Trim()
                if ($clean) {
                    $output.Add($clean)
                    Write-LiaisonUnifiedLog ("WSL|" + $clean)
                }
            }
        } catch {
            Write-LiaisonUnifiedLog ("WARNING|Could not decode WSL output: " + $_.Exception.Message)
        }
    }
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

    Write-LiaisonUnifiedLog ("WSL exit code: " + $exitCode)
    return [pscustomobject]@{ ExitCode = $exitCode; TimedOut = $timedOut; Output = @($output) }
}

function Get-LiaisonWslDetail($Result) {
    $joined = (@($Result.Output) -join " | ")
    if ($joined -match "HCS_E_HYPERV_NOT_INSTALLED|Wsl/Service/RegisterDistro/CreateVm/HCS") {
        return "LIAISON_HYPERVISOR_NOT_RUNNING: The Windows hypervisor is not running."
    }
    $tail = @($Result.Output | Select-Object -Last 12)
    if ($tail.Count -eq 0) { return "WSL returned no diagnostic output." }
    return ($tail -join " | ")
}

function Get-LiaisonBootHypervisorLaunchType {
    try {
        $raw = @(& "$env:SystemRoot\System32\bcdedit.exe" /enum "{current}" 2>&1)
        $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
        $match = [regex]::Match($text, "(?im)^\s*hypervisorlaunchtype\s+(\S+)\s*$")
        if ($match.Success) { return $match.Groups[1].Value }
    } catch {
        Write-LiaisonUnifiedLog ("WARNING|Could not read hypervisorlaunchtype: " + $_.Exception.Message)
    }
    return $null
}

function Set-LiaisonBootHypervisorAuto {
    $process = Start-Process `
        -FilePath "$env:SystemRoot\System32\bcdedit.exe" `
        -ArgumentList @("/set", "hypervisorlaunchtype", "auto") `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
    if ($process.ExitCode -ne 0) {
        throw ("Could not enable the Windows hypervisor boot setting. BCDEdit exit code: " + $process.ExitCode + ".")
    }
    Write-LiaisonUnifiedLog "Windows hypervisor boot setting changed to auto."
}

function Ensure-LiaisonWslFeatures {
    Write-LiaisonProgress 18 "Virtualization check" "Checking CPU virtualization, Windows features, and the hypervisor boot setting."

    $computerSystem = $null
    $processor = $null
    try { $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop } catch { }
    try { $processor = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1 } catch { }

    $hypervisorPresent = $false
    if ($computerSystem -and $null -ne $computerSystem.HypervisorPresent) {
        $hypervisorPresent = [bool]$computerSystem.HypervisorPresent
    }

    if (-not $hypervisorPresent -and $processor) {
        if ($null -ne $processor.VMMonitorModeExtensions -and -not [bool]$processor.VMMonitorModeExtensions) {
            Write-LiaisonUnifiedLog "LIAISON_CPU_VIRTUALIZATION_UNSUPPORTED"
            throw "LIAISON_CPU_VIRTUALIZATION_UNSUPPORTED: This processor or virtual machine does not expose the virtualization extensions required by WSL 2."
        }
        if ($null -ne $processor.SecondLevelAddressTranslationExtensions -and -not [bool]$processor.SecondLevelAddressTranslationExtensions) {
            Write-LiaisonUnifiedLog "LIAISON_CPU_VIRTUALIZATION_UNSUPPORTED"
            throw "LIAISON_CPU_VIRTUALIZATION_UNSUPPORTED: Second-level address translation is not available, so WSL 2 cannot start."
        }
        if ($null -ne $processor.VirtualizationFirmwareEnabled -and -not [bool]$processor.VirtualizationFirmwareEnabled) {
            Write-LiaisonUnifiedLog "LIAISON_FIRMWARE_VIRTUALIZATION_DISABLED"
            throw "LIAISON_FIRMWARE_VIRTUALIZATION_DISABLED: Hardware virtualization is disabled in BIOS or UEFI. Enable Intel VT-x, Intel Virtualization Technology, AMD-V, or SVM, then start Windows and retry."
        }
    }

    $restartRequired = $false
    foreach ($featureName in @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform")) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction Stop
        Write-LiaisonUnifiedLog ("Windows feature " + $featureName + ": " + $feature.State)
        if ($feature.State -eq "Enabled") { continue }
        if ($feature.State -match "Pending") {
            $restartRequired = $true
            continue
        }

        Write-LiaisonProgress 19 "Virtualization repair" ("Enabling Windows feature " + $featureName + ".")
        Enable-WindowsOptionalFeature -Online -FeatureName $featureName -All -NoRestart -ErrorAction Stop | Out-Null
        $restartRequired = $true
    }

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw "wsl.exe is unavailable after enabling the required Windows features. Restart Windows and retry."
    }

    $launchType = Get-LiaisonBootHypervisorLaunchType
    Write-LiaisonUnifiedLog ("hypervisorlaunchtype: " + $(if ($launchType) { $launchType } else { "unknown" }))
    if ($launchType -and $launchType -ieq "Off") {
        Write-LiaisonProgress 20 "Hypervisor repair" "Enabling the Windows hypervisor at startup."
        Set-LiaisonBootHypervisorAuto
        $restartRequired = $true
    } elseif (-not $hypervisorPresent -and -not $restartRequired) {
        # Firmware virtualization is available, but the hypervisor is not active. Restores,
        # boot tools, and older VM software can leave the BCD setting disabled or stale.
        Write-LiaisonProgress 20 "Hypervisor repair" "Repairing the Windows hypervisor startup setting."
        Set-LiaisonBootHypervisorAuto
        $restartRequired = $true
    }

    if ($restartRequired) {
        Write-LiaisonUnifiedLog "LIAISON_HYPERVISOR_RESTART_REQUIRED"
        Write-LiaisonProgress 21 "Windows restart" "Virtualization settings were repaired. Restart Windows before continuing."
        throw "LIAISON_HYPERVISOR_RESTART_REQUIRED: Required WSL 2 virtualization settings were repaired. Restart Windows, reopen Liaison Setup, and retry the same role."
    }

    Write-LiaisonProgress 22 "Virtualization ready" "The Windows hypervisor is running and WSL 2 can be started."
}
