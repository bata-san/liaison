# Overrides the basic WSL distribution installer with a process-based implementation.
# Start-Process provides a reliable numeric exit code and lets the unified installer
# stream stdout/stderr while Ubuntu is downloading and registering.

function Get-LiaisonWslDistributions {
    $names = @()
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $raw = @(& "$env:SystemRoot\System32\wsl.exe" --list --quiet 2>&1)
        foreach ($item in $raw) {
            $name = (([string]$item) -replace "\x00", "").Trim()
            if ($name -and $name -notmatch "^(Windows Subsystem|Copyright|Usage:|Error:)") {
                $names += $name
            }
        }
    } catch {
        # Registry fallback below handles older/incomplete WSL installations.
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $registryRoot = "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Lxss"
    if (Test-Path -LiteralPath $registryRoot) {
        $names += @(
            Get-ChildItem -LiteralPath $registryRoot -ErrorAction SilentlyContinue |
                ForEach-Object {
                    try {
                        $value = (Get-ItemProperty -LiteralPath $_.PSPath -Name DistributionName -ErrorAction Stop).DistributionName
                        if ($value) { ([string]$value).Trim() }
                    } catch {
                        # Ignore incomplete registrations.
                    }
                }
        )
    }

    return @($names | Where-Object { $_ } | Sort-Object -Unique)
}

function ConvertTo-LiaisonProcessArgument([string]$Value) {
    if ($null -eq $Value) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-LiaisonWslInstallProcess {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 1200
    )

    $stdoutPath = Join-Path $env:TEMP ("LiaisonWslInstall-{0}.stdout.log" -f ([Guid]::NewGuid().ToString("N")))
    $stderrPath = Join-Path $env:TEMP ("LiaisonWslInstall-{0}.stderr.log" -f ([Guid]::NewGuid().ToString("N")))
    $argumentLine = ($Arguments | ForEach-Object { ConvertTo-LiaisonProcessArgument ([string]$_) }) -join " "
    $startedAt = [DateTimeOffset]::Now
    $stdoutCount = 0
    $stderrCount = 0
    $captured = New-Object Collections.Generic.List[string]

    Write-Host ("Running: wsl.exe " + $argumentLine)
    try {
        $process = Start-Process `
            -FilePath "$env:SystemRoot\System32\wsl.exe" `
            -ArgumentList $argumentLine `
            -WindowStyle Hidden `
            -PassThru `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath

        while (-not $process.HasExited) {
            foreach ($source in @(
                @{ Path = $stdoutPath; Count = $stdoutCount; Prefix = "WSL" },
                @{ Path = $stderrPath; Count = $stderrCount; Prefix = "WSL stderr" }
            )) {
                if (Test-Path -LiteralPath $source.Path) {
                    $lines = @(Get-Content -LiteralPath $source.Path -ErrorAction SilentlyContinue)
                    for ($index = [int]$source.Count; $index -lt $lines.Count; $index++) {
                        $line = (([string]$lines[$index]) -replace "\x00", "").TrimEnd()
                        if ($line) {
                            Write-Host ("{0}: {1}" -f $source.Prefix, $line)
                            $captured.Add($line)
                        }
                    }
                    if ($source.Prefix -eq "WSL") { $stdoutCount = $lines.Count } else { $stderrCount = $lines.Count }
                }
            }

            if (([DateTimeOffset]::Now - $startedAt).TotalSeconds -ge $TimeoutSeconds) {
                try { $process.Kill() } catch { }
                Write-Warning ("WSL command exceeded {0} seconds and was stopped." -f $TimeoutSeconds)
                return [pscustomobject]@{ ExitCode = 1460; TimedOut = $true; Output = @($captured) }
            }
            Start-Sleep -Milliseconds 700
            $process.Refresh()
        }

        foreach ($path in @($stdoutPath, $stderrPath)) {
            if (Test-Path -LiteralPath $path) {
                foreach ($item in @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
                    $line = (([string]$item) -replace "\x00", "").TrimEnd()
                    if ($line -and -not $captured.Contains($line)) {
                        Write-Host $line
                        $captured.Add($line)
                    }
                }
            }
        }

        $process.Refresh()
        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            TimedOut = $false
            Output = @($captured)
        }
    } catch {
        $captured.Add($_.Exception.Message)
        Write-Warning ("WSL command could not be started: " + $_.Exception.Message)
        return [pscustomobject]@{ ExitCode = -1; TimedOut = $false; Output = @($captured) }
    } finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Wait-LiaisonWslDistribution {
    param(
        [Parameter(Mandatory = $true)][string]$Distribution,
        [int]$TimeoutSeconds = 120
    )

    for ($attempt = 0; $attempt -lt $TimeoutSeconds; $attempt++) {
        $installed = @(Get-LiaisonWslDistributions)
        $match = $installed | Where-Object { $_ -ieq $Distribution } | Select-Object -First 1
        if (-not $match -and $Distribution -like "Ubuntu*") {
            $match = $installed | Where-Object { $_ -like "Ubuntu*" } | Sort-Object -Descending | Select-Object -First 1
        }
        if ($match) { return [string]$match }
        Start-Sleep -Seconds 1
    }
    return $null
}

function Ensure-LiaisonWslDistribution {
    param([Parameter(Mandatory = $true)][string]$Distribution)

    $existing = Wait-LiaisonWslDistribution -Distribution $Distribution -TimeoutSeconds 1
    if ($existing) { return $existing }

    Write-LiaisonDependencyStep "Checking the WSL runtime and online distribution catalog"
    $status = Invoke-LiaisonWslInstallProcess -Arguments @("--status") -TimeoutSeconds 60
    $online = Invoke-LiaisonWslInstallProcess -Arguments @("--list", "--online") -TimeoutSeconds 120
    if ($online.ExitCode -ne 0) {
        Write-Warning "The WSL online distribution catalog could not be queried. Direct download will still be attempted."
    }

    $attempts = @(
        @{ Name = "direct web download"; Arguments = @("--install", "-d", $Distribution, "--no-launch", "--web-download") },
        @{ Name = "direct web download compatibility mode"; Arguments = @("--install", "-d", $Distribution, "--web-download") }
    )

    $results = New-Object Collections.Generic.List[object]
    foreach ($attempt in $attempts) {
        Write-LiaisonDependencyStep ("Installing the {0} WSL distribution using {1}" -f $Distribution, $attempt.Name)
        $result = Invoke-LiaisonWslInstallProcess -Arguments $attempt.Arguments -TimeoutSeconds 1200
        $results.Add([pscustomobject]@{ Name = $attempt.Name; Result = $result })
        $registered = Wait-LiaisonWslDistribution -Distribution $Distribution -TimeoutSeconds 45
        if ($registered) {
            $Distribution = $registered
            break
        }

        $joined = (@($result.Output) -join "`n")
        if ($joined -match "restart|reboot|0x800701bc|0x80370102|0x8007019e") {
            throw "Ubuntu download could not finish because WSL requires a Windows restart or runtime update. Restart Windows, then open Liaison Setup and retry. Last WSL output: $($joined.Trim())"
        }
    }

    $registered = Wait-LiaisonWslDistribution -Distribution $Distribution -TimeoutSeconds 1
    if (-not $registered) {
        Write-LiaisonDependencyStep "Updating WSL through the direct web channel"
        $update = Invoke-LiaisonWslInstallProcess -Arguments @("--update", "--web-download") -TimeoutSeconds 600
        $results.Add([pscustomobject]@{ Name = "WSL runtime update"; Result = $update })

        Write-LiaisonDependencyStep ("Retrying the {0} direct download" -f $Distribution)
        $retry = Invoke-LiaisonWslInstallProcess -Arguments @("--install", "-d", $Distribution, "--web-download") -TimeoutSeconds 1200
        $results.Add([pscustomobject]@{ Name = "direct download after update"; Result = $retry })
        $registered = Wait-LiaisonWslDistribution -Distribution $Distribution -TimeoutSeconds 90
    }

    if (-not $registered) {
        Write-LiaisonDependencyStep ("Trying the Microsoft Store installation channel for {0}" -f $Distribution)
        $store = Invoke-LiaisonWslInstallProcess -Arguments @("--install", "-d", $Distribution, "--no-launch") -TimeoutSeconds 1200
        $results.Add([pscustomobject]@{ Name = "Microsoft Store channel"; Result = $store })
        $registered = Wait-LiaisonWslDistribution -Distribution $Distribution -TimeoutSeconds 90
    }

    if (-not $registered) {
        $summary = @(
            $results | ForEach-Object {
                $tail = @($_.Result.Output | Select-Object -Last 5) -join " | "
                "{0}: exit {1}{2}; {3}" -f $_.Name, $_.Result.ExitCode, $(if ($_.Result.TimedOut) { " (timeout)" } else { "" }), $tail
            }
        ) -join " || "
        throw "Ubuntu could not be registered in WSL after direct-download, runtime-update, and Store attempts. $summary"
    }

    Write-Host ("WSL distribution registered: " + $registered) -ForegroundColor Green
    $initialise = Invoke-LiaisonWslInstallProcess -Arguments @("-d", $registered, "-u", "root", "--exec", "sh", "-lc", "true") -TimeoutSeconds 180
    if ($initialise.ExitCode -ne 0) {
        $detail = @($initialise.Output | Select-Object -Last 8) -join " | "
        throw "The $registered WSL distribution was downloaded but could not be initialized. Restart Windows and retry. Last WSL output: $detail"
    }

    return $registered
}
