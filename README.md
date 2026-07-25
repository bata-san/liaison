# Liaison

Liaison is a lightweight, rich workstation orchestrator for a school-owned Windows 11 Pro workstation.
It keeps Windows native for classroom use while splitting a shared remote resource pool into two persistent slots and up to five workspace slots.

## What is implemented

- Rust Windows service with a loopback-only, token-authenticated control protocol.
- Dynamic CPU and RAM distribution across 0–5 workspace slots.
- Two protected persistent slots.
- Remote, Class, Local-exclusive, and Maintenance modes.
- Exclusive/shared GPU reservation policy.
- Safe mock runtime for GUI and workflow testing without touching WSL or Docker.
- WSL Docker runtime adapter for the real host.
- Tauri 2 desktop dashboard using the Windows WebView2 runtime.
- Rust CLI for diagnostics and automation.
- Windows smoke tests covering the complete control flow.

## Why this stays lightweight

- The always-on service is Rust and uses the standard TCP stack rather than an embedded web server.
- Runtime state is persisted as JSON; there is no database daemon.
- The GUI uses Tauri/WebView2 rather than shipping a Chromium/Electron process tree.
- The frontend is vanilla TypeScript and CSS with no UI framework.
- The GUI may be closed while the service continues to run.

## Safe demo

The mock runtime does not start WSL, Docker, containers, or GPU workloads.

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run-demo.ps1
```

For a terminal-only demonstration:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run-demo.ps1 -NoGui
```

## Automated test

```powershell
powershell -ExecutionPolicy Bypass -File scripts\test-all.ps1
```

The end-to-end smoke test verifies service startup, a five-way workspace split, GPU reservation, Class throttling, and Local-exclusive protection of P1/P2.

## Development prerequisites

- Windows 11 Pro
- Rust stable with the MSVC toolchain
- Microsoft C++ Build Tools
- Node.js 22 or newer
- Microsoft Edge WebView2 Runtime

```powershell
npm --prefix apps/liaison-desktop install
cargo test --workspace
npm --prefix apps/liaison-desktop run build
```

## Runtime modes

### Mock

Use for development, GUI review, tests, and CI. No workstation resources are changed.

### WSL Docker

Uses `wsl.exe -d LiaisonRuntime -- docker ...`. The adapter creates one container per slot, applies CPU/RAM limits, stores each workspace in a named volume, and recreates a container when GPU access changes.

## Security boundary

- The service listens only on `127.0.0.1` or `::1`.
- Every request requires a local token of at least 16 characters.
- The desktop and CLI send structured commands, never arbitrary PowerShell.
- Workspace containers do not receive the Docker socket or Windows administrator access.
- Tailscale remains the external network boundary.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/TESTING.md](docs/TESTING.md).
