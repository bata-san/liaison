# Liaison

Liaison is a lightweight workstation orchestrator for a school-owned Windows 11 Pro workstation.
It keeps the host usable as a normal Windows PC while exposing persistent and workspace resource pools to approved remote users over Tailscale.

## Design goals

- Keep the Windows host native for classroom use.
- Keep the always-on footprint small.
- Split one workspace pool into 3–5 disposable slots on demand.
- Keep two persistent service slots alive across classroom mode changes.
- Reserve GPU access instead of pretending one GPU can always be divided evenly.
- Provide a rich local dashboard without shipping an Electron runtime.

## Technology

- **Rust** for the Windows service, orchestration logic, and native commands.
- **Tauri 2** for the desktop shell.
- **Vanilla TypeScript and CSS** for a rich UI with minimal frontend overhead.
- **Windows WebView2** supplied by the operating system.
- **WSL/container runtime adapters** behind a stable Rust interface.

## Repository layout

```text
apps/
  liaison-service/        Windows background service
  liaison-desktop/        Tauri desktop dashboard
crates/
  liaison-core/           Shared domain models and policies
docs/
  ARCHITECTURE.md         System architecture
scripts/
  install-service.ps1     Initial local service installation
```

## Development

Prerequisites on Windows:

- Rust stable with the MSVC target
- Microsoft C++ Build Tools
- Microsoft Edge WebView2
- Node.js for frontend build tooling only

```powershell
npm --prefix apps/liaison-desktop install
npm --prefix apps/liaison-desktop run tauri dev
```

The current dashboard uses an in-process demo state. The next milestone connects it to the Windows service through a restricted local IPC protocol.
