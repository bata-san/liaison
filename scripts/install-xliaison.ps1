param(
    [ValidateSet("Prompt", "Server", "Client", "Both")]
    [string]$Role = "Prompt",
    [string]$ConnectionFile,
    [string]$WslDistribution = "Ubuntu",
    [switch]$LocalOnly,
    [switch]$SkipDependencyInstall,
    [switch]$NoLaunch,
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$SetupLog = Join-Path $env:TEMP "xLiaisonSetup.log"
$ResumeRoot = Join-Path $env:ProgramData "xLiaison\SetupCache"
$RunOncePath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
$RunOnceName = "xLiaisonSetupResume"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-ProcessArgument([string]$Value) {
    if ($null -eq $Value) { return '""' }
    if ($Value.Contains('"')) {
        throw "A setup argument contains an unsupported quote character."
    }
    return '"' + $Value + '"'
}

function Get-SelfArguments {
    $parts = @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", (Quote-ProcessArgument $PSCommandPath),
        "-Role", $Role,
        "-WslDistribution", (Quote-ProcessArgument $WslDistribution)
    )
    if ($ConnectionFile) {
        $parts += @("-ConnectionFile", (Quote-ProcessArgument $ConnectionFile))
    }
    if ($LocalOnly) { $parts += "-LocalOnly" }
    if ($SkipDependencyInstall) { $parts += "-SkipDependencyInstall" }
    if ($NoLaunch) { $parts += "-NoLaunch" }
    if ($NonInteractive) { $parts += "-NonInteractive" }
    return ($parts -join " ")
}

if (-not (Test-Administrator)) {
    try {
        $process = Start-Process `
            -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -Verb RunAs `
            -Wait `
            -PassThru `
            -ArgumentList (Get-SelfArguments)
        exit $process.ExitCode
    } catch {
        Write-Host "Administrator approval is required to install xLiaison." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 1
    }
}

function Show-RoleDialog {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    [Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object Windows.Forms.Form
    $form.Text = "xLiaison Setup"
    $form.StartPosition = "CenterScreen"
    $form.ClientSize = New-Object Drawing.Size(520, 360)
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true

    $title = New-Object Windows.Forms.Label
    $title.Text = "インストールする役割を選択してください"
    $title.Font = New-Object Drawing.Font("Yu Gothic UI", 14, [Drawing.FontStyle]::Bold)
    $title.AutoSize = $true
    $title.Location = New-Object Drawing.Point(28, 24)
    $form.Controls.Add($title)

    $description = New-Object Windows.Forms.Label
    $description.Text = "選択後は、依存関係の導入、設定、自動起動、疎通確認まで自動で進みます。"
    $description.Font = New-Object Drawing.Font("Yu Gothic UI", 9)
    $description.AutoSize = $true
    $description.Location = New-Object Drawing.Point(30, 62)
    $form.Controls.Add($description)

    $client = New-Object Windows.Forms.RadioButton
    $client.Text = "クライアント版"
    $client.Checked = $true
    $client.AutoSize = $true
    $client.Location = New-Object Drawing.Point(44, 105)
    $form.Controls.Add($client)

    $server = New-Object Windows.Forms.RadioButton
    $server.Text = "サーバー版"
    $server.AutoSize = $true
    $server.Location = New-Object Drawing.Point(44, 139)
    $form.Controls.Add($server)

    $both = New-Object Windows.Forms.RadioButton
    $both.Text = "サーバー版とクライアント版の両方"
    $both.AutoSize = $true
    $both.Location = New-Object Drawing.Point(44, 173)
    $form.Controls.Add($both)

    $local = New-Object Windows.Forms.CheckBox
    $local.Text = "サーバーをこのPC内だけで使う（Tailscaleを設定しない）"
    $local.AutoSize = $true
    $local.Location = New-Object Drawing.Point(44, 221)
    $form.Controls.Add($local)

    $launch = New-Object Windows.Forms.CheckBox
    $launch.Text = "セットアップ完了後にクライアントを起動しない"
    $launch.AutoSize = $true
    $launch.Location = New-Object Drawing.Point(44, 251)
    $form.Controls.Add($launch)

    $note = New-Object Windows.Forms.Label
    $note.Text = "初回のみ、WSL有効化後のWindows再起動やTailscaleのブラウザログインが必要な場合があります。"
    $note.Font = New-Object Drawing.Font("Yu Gothic UI", 8)
    $note.ForeColor = [Drawing.Color]::DimGray
    $note.AutoSize = $true
    $note.Location = New-Object Drawing.Point(30, 292)
    $form.Controls.Add($note)

    $install = New-Object Windows.Forms.Button
    $install.Text = "インストール"
    $install.DialogResult = [Windows.Forms.DialogResult]::OK
    $install.Size = New-Object Drawing.Size(112, 34)
    $install.Location = New-Object Drawing.Point(376, 314)
    $form.AcceptButton = $install
    $form.Controls.Add($install)

    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = "キャンセル"
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $cancel.Size = New-Object Drawing.Size(96, 34)
    $cancel.Location = New-Object Drawing.Point(268, 314)
    $form.CancelButton = $cancel
    $form.Controls.Add($cancel)

    $result = $form.ShowDialog()
    if ($result -ne [Windows.Forms.DialogResult]::OK) {
        return $null
    }

    $selectedRole = if ($server.Checked) {
        "Server"
    } elseif ($both.Checked) {
        "Both"
    } else {
        "Client"
    }

    return [pscustomobject]@{
        Role = $selectedRole
        LocalOnly = $local.Checked
        NoLaunch = $launch.Checked
    }
}

function Invoke-Installer([string[]]$Arguments) {
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @Arguments
    return $LASTEXITCODE
}

function Test-WslRestartRequired {
    try {
        $wsl = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux
        $vm = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
        return $wsl.State -eq "EnablePending" -or $vm.State -eq "EnablePending"
    } catch {
        return $false
    }
}

function Register-SetupResume {
    New-Item -ItemType Directory -Force -Path $ResumeRoot | Out-Null
    Copy-Item -Path (Join-Path $Root "*") -Destination $ResumeRoot -Recurse -Force

    $resumeScript = Join-Path $ResumeRoot "scripts\install-xliaison.ps1"
    $argumentParts = @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", (Quote-ProcessArgument $resumeScript),
        "-Role", $Role,
        "-WslDistribution", (Quote-ProcessArgument $WslDistribution),
        "-NonInteractive"
    )
    if ($ConnectionFile) {
        $argumentParts += @("-ConnectionFile", (Quote-ProcessArgument $ConnectionFile))
    }
    if ($LocalOnly) { $argumentParts += "-LocalOnly" }
    if ($SkipDependencyInstall) { $argumentParts += "-SkipDependencyInstall" }
    if ($NoLaunch) { $argumentParts += "-NoLaunch" }

    $command = 'powershell.exe ' + ($argumentParts -join " ")
    New-Item -Path $RunOncePath -Force | Out-Null
    New-ItemProperty -Path $RunOncePath -Name $RunOnceName -Value $command -PropertyType String -Force | Out-Null
}

if ($Role -eq "Prompt") {
    if ($NonInteractive) {
        throw "A role must be specified when -NonInteractive is used."
    }
    $selection = Show-RoleDialog
    if (-not $selection) {
        exit 0
    }
    $Role = $selection.Role
    $LocalOnly = [bool]$selection.LocalOnly
    $NoLaunch = [bool]$selection.NoLaunch
}

$transcriptStarted = $false
try {
    try {
        Start-Transcript -Path $SetupLog -Append | Out-Null
        $transcriptStarted = $true
    } catch {
        Write-Warning "The setup log could not be started: $($_.Exception.Message)"
    }

    Write-Host "`n=== xLiaison Setup ===" -ForegroundColor Cyan
    Write-Host "Role: $Role"
    Write-Host "Log: $SetupLog"

    $serverRequested = $Role -in @("Server", "Both")
    $clientRequested = $Role -in @("Client", "Both")

    if ($serverRequested) {
        $serverScript = Join-Path $PSScriptRoot "install-server-bundle.ps1"
        if (-not (Test-Path $serverScript)) {
            throw "Server installer is missing: $serverScript"
        }

        $serverArguments = @(
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $serverScript,
            "-WslDistribution", $WslDistribution
        )
        if ($LocalOnly) { $serverArguments += "-LocalOnly" }
        if ($SkipDependencyInstall) { $serverArguments += "-SkipDependencyInstall" }

        Write-Host "`nInstalling xLiaison Server..." -ForegroundColor Cyan
        $serverExit = Invoke-Installer $serverArguments
        if ($serverExit -ne 0) {
            if (Test-WslRestartRequired) {
                Register-SetupResume
                Write-Host "`nWindows must restart to finish enabling WSL." -ForegroundColor Yellow
                Write-Host "xLiaison Setup will continue automatically after the next sign-in." -ForegroundColor Yellow
                exit 0
            }
            throw "Server setup failed with exit code $serverExit."
        }
    }

    if ($clientRequested) {
        $clientScript = Join-Path $PSScriptRoot "install-client-bundle.ps1"
        if (-not (Test-Path $clientScript)) {
            throw "Client installer is missing: $clientScript"
        }

        $resolvedConnectionFile = $ConnectionFile
        if (-not $resolvedConnectionFile -and $Role -eq "Both") {
            $generatedConnection = Join-Path $env:USERPROFILE "Desktop\liaison-client.json"
            if (Test-Path $generatedConnection) {
                $resolvedConnectionFile = $generatedConnection
            }
        }

        $clientArguments = @(
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $clientScript
        )
        if ($resolvedConnectionFile) {
            $clientArguments += @("-ConnectionFile", $resolvedConnectionFile)
        }
        if ($SkipDependencyInstall -or $serverRequested) {
            $clientArguments += "-SkipDependencyInstall"
        }
        if ($NoLaunch) {
            $clientArguments += "-NoLaunch"
        }

        Write-Host "`nInstalling xLiaison Client..." -ForegroundColor Cyan
        $clientExit = Invoke-Installer $clientArguments
        if ($clientExit -ne 0) {
            throw "Client setup failed with exit code $clientExit."
        }
    }

    Remove-ItemProperty -Path $RunOncePath -Name $RunOnceName -ErrorAction SilentlyContinue
    Write-Host "`nxLiaison setup completed." -ForegroundColor Green
    if ($Role -eq "Server") {
        Write-Host "The pairing code and liaison-client.json are on the desktop."
    } elseif ($Role -eq "Both") {
        Write-Host "The client was configured from the server pairing information automatically."
    }
} catch {
    Write-Host "`nxLiaison setup failed." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Setup log: $SetupLog"
    exit 1
} finally {
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
}
