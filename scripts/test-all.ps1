$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Push-Location $Root
try {
    cargo test --workspace
    if ($LASTEXITCODE -ne 0) { throw "Rust tests failed" }

    Push-Location "apps\liaison-desktop"
    try {
        npm install
        npm run build
        if ($LASTEXITCODE -ne 0) { throw "Frontend build failed" }
    } finally {
        Pop-Location
    }

    & "$PSScriptRoot\smoke-test.ps1"
} finally {
    Pop-Location
}
