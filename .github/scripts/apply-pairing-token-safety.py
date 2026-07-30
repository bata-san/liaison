from pathlib import Path


def replace_once(path: str, old: str, new: str, marker: str) -> None:
    file = Path(path)
    text = file.read_text(encoding="utf-8-sig")
    if marker in text:
        print(f"{path}: pairing token safety already applied")
        return
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Expected exactly one patch location in {path}, found {count}")
    file.write_text(text.replace(old, new, 1), encoding="utf-8", newline="\n")
    print(f"{path}: pairing token safety applied")


replace_once(
    "scripts/setup-server.ps1",
    '''    [string]$ConnectionFile = "$env:USERPROFILE\\Desktop\\liaison-client.json",
    [switch]$LocalOnly,
    [switch]$SkipBuild''',
    '''    [string]$ConnectionFile = "$env:USERPROFILE\\Desktop\\liaison-client.json",
    [switch]$LocalOnly,
    [switch]$RotateToken,
    [switch]$SkipBuild''',
    "[switch]$RotateToken",
)

replace_once(
    "scripts/setup-server.ps1",
    '''    $Token = $null
    if (Test-Path $ConfigPath) {''',
    '''    $Token = $null
    if (-not $RotateToken -and (Test-Path $ConfigPath)) {''',
    "-not $RotateToken -and",
)

replace_once(
    "scripts/setup-server.ps1",
    '    Write-Host "Pairing code: $PairingCode"',
    '    Write-Host "Pairing information file: $PairingFile"',
    "Pairing information file:",
)

replace_once(
    "scripts/install-server-core.ps1",
    '''        "-File", (Join-Path $PSScriptRoot "setup-server.ps1"),
        "-WslDistribution", $WslDistribution,
        "-SkipBuild"''',
    '''        "-File", (Join-Path $PSScriptRoot "setup-server.ps1"),
        "-WslDistribution", $WslDistribution,
        "-RotateToken",
        "-SkipBuild"''',
    '"-RotateToken",',
)

replace_once(
    "scripts/install-server-bundle.ps1",
    '''    $clean = (($Line -replace "\\x00", "").Trim())
    if (-not $clean -or (Test-LiaisonTranscriptNoise $clean)) { return }''',
    '''    $clean = (($Line -replace "\\x00", "").Trim())
    if (-not $clean -or (Test-LiaisonTranscriptNoise $clean)) { return }
    $clean = [regex]::Replace($clean, "(?i)(token=)[^&\\s]+", '$1[redacted]')''',
    "'$1[redacted]'",
)
