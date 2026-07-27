param(
    [string]$WslDistribution = "Ubuntu",
    [switch]$LocalOnly,
    [switch]$SkipDependencyInstall
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$InstallLog = Join-Path $env:TEMP "LiaisonServerInstall.log"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-WslDistribution", "`"$WslDistribution`""
    )
    if ($LocalOnly) { $arguments += "-LocalOnly" }
    if ($SkipDependencyInstall) { $arguments += "-SkipDependencyInstall" }
    $process = Start-Process -FilePath "powershell.exe" -Verb RunAs -Wait -PassThru -ArgumentList $arguments
    exit $process.ExitCode
}

. (Join-Path $PSScriptRoot "bootstrap-dependencies.ps1")

$transcriptStarted = $false
try {
    Start-Transcript -Path $InstallLog -Append | Out-Null
    $transcriptStarted = $true
} catch {
    Write-Warning "Installation transcript could not be started: $($_.Exception.Message)"
}

$exitCode = 0
try {
    Add-LiaisonToolPaths | Out-Null

    if (-not $SkipDependencyInstall) {
        if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
            Write-LiaisonDependencyStep "Installing Windows Subsystem for Linux"
            & dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
            & dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
            throw "WSL was enabled. Restart Windows, then run Install Liaison Server.cmd again."
        }

        $distributions = Get-LiaisonWslDistributions
        if ($distributions -notcontains $WslDistribution) {
            Write-LiaisonDependencyStep "Installing the $WslDistribution WSL distribution"
            & wsl.exe --install -d $WslDistribution --no-launch
            if ($LASTEXITCODE -ne 0) {
                throw "The WSL distribution could not be installed. Restart Windows and run setup again."
            }
            & wsl.exe -d $WslDistribution -u root -- sh -lc "true"
            if ($LASTEXITCODE -ne 0) {
                throw "The WSL distribution was installed but could not be initialized. Restart Windows and run setup again."
            }
        }

        Install-LiaisonDockerEngineInWsl -Distribution $WslDistribution

        if (-not $LocalOnly) {
            $tailscaleIp = Connect-LiaisonTailscale -InstallIfMissing
            if (-not $tailscaleIp) {
                Write-Warning "Tailscale is not signed in. The server will be configured as local-only."
                $LocalOnly = $true
            }
        }
    }

    # The control server must start before Docker workers. Persistent workers are
    # started later by the resilient host script, so an image pull or container
    # failure cannot terminate the Liaison control service.
    $templatePath = Join-Path $Root "config\liaison.example.json"
    $template = Get-Content $templatePath -Raw | ConvertFrom-Json
    if ($template.PSObject.Properties.Name -contains "persistent_autostart") {
        $template.persistent_autostart = $false
    } else {
        $template | Add-Member -NotePropertyName persistent_autostart -NotePropertyValue $false
    }
    [IO.File]::WriteAllText(
        $templatePath,
        ($template | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false)
    )

    $setupArguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $PSScriptRoot "setup-server.ps1"),
        "-WslDistribution", $WslDistribution,
        "-SkipBuild"
    )
    if ($LocalOnly) { $setupArguments += "-LocalOnly" }

    & powershell.exe @setupArguments
    if ($LASTEXITCODE -ne 0) {
        throw "The base Liaison Server setup failed with exit code $LASTEXITCODE."
    }

    & (Join-Path $PSScriptRoot "repair-windows-server.ps1") -WslDistribution $WslDistribution
    if ($LASTEXITCODE -ne 0) {
        throw "The resilient Windows startup configuration failed."
    }

    Write-Host ""
    Write-Host "Liaison Server installation completed." -ForegroundColor Green
    Write-Host "Installation log: $InstallLog"
    Write-Host "Runtime logs: $env:ProgramData\Liaison\logs"
    $pairingPath = Join-Path $env:USERPROFILE "Desktop\Liaison Pairing Code.txt"
    if (Test-Path $pairingPath) {
        Write-Host "Pairing code: $pairingPath"
    }
} catch {
    $exitCode = 1
    Write-Host ""
    Write-Host "Liaison Server installation failed." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Installation log: $InstallLog"
    Write-Host "Runtime logs: $env:ProgramData\Liaison\logs"
} finally {
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
}

exit $exitCode
