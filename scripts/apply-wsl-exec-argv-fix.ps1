param(
    [string]$SourcePath
)

# Keep this file ASCII-only for Windows PowerShell 5.1 compatibility.
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
if (-not $SourcePath) {
    $SourcePath = Join-Path $Root "crates\liaison-runtime\src\lib.rs"
}

if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    throw "The Liaison runtime source was not found: $SourcePath"
}

$text = [IO.File]::ReadAllText($SourcePath)
$old = '.arg("--")'
$new = '.arg("--exec")'
$oldCount = ([regex]::Matches($text, [regex]::Escape($old))).Count
$newCount = ([regex]::Matches($text, [regex]::Escape($new))).Count

if ($newCount -eq 1 -and $oldCount -eq 0) {
    Write-Host "WSL direct argv execution fix is already applied."
    return
}
if ($oldCount -ne 1 -or $newCount -ne 0) {
    throw "Expected exactly one WSL command separator to replace. Found old=$oldCount new=$newCount."
}

$text = $text.Replace($old, $new)
if ($text -notmatch [regex]::Escape('{{.State.Running}}|{{.HostConfig.NanoCpus}}|{{.HostConfig.Memory}}|{{.HostConfig.MemorySwap}}')) {
    throw "The Docker inspect resource template was not found after applying the WSL fix."
}

[IO.File]::WriteAllText($SourcePath, $text, [Text.UTF8Encoding]::new($false))
Write-Host "WSL commands now use --exec so Docker arguments bypass the Linux shell."
