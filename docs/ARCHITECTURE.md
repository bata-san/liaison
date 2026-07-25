# Liaison architecture

## Runtime shape

Liaison deliberately separates the privileged always-on process from the rich user interface.

```text
Windows 11 Pro
├─ LiaisonService.exe      Rust Windows service, no GUI
├─ Liaison.exe             Tauri/WebView2 dashboard, opened on demand
├─ Tailscale               Private transport
└─ Runtime adapter
   ├─ Persistent pool      P1–P2
   └─ Workspace pool       W1–W5
```

The GUI can be closed without affecting workloads. The service owns privileged operations and exposes only a narrow local IPC contract.

## Lightweight policy

- No Electron or bundled Chromium.
- No frontend framework in the first release.
- No always-on Node.js process.
- No external database in the first release.
- Append-only structured logs and small configuration files are preferred.
- Runtime integrations are loaded only when required.
- Slot metrics are sampled at a low rate while the dashboard is closed.

## Rich UI policy

Visual richness comes from CSS, native WebView rendering, small SVG elements, and carefully limited animation. It does not require a large JavaScript framework.

## Security boundary

The desktop app is unprivileged. The Windows service validates every state-changing request. Future IPC must use Windows named pipes with an explicit ACL rather than an open TCP listener.

The service must never expose a generic command execution endpoint. Each allowed operation is represented by a typed command such as `SetMode`, `StartSlot`, `StopSlot`, or `ResizePool`.

## Runtime abstraction

The shared Rust model will be extended with a `RuntimeAdapter` trait. Initial implementations may call a WSL/Docker-compatible backend. A future WSL Containers backend can be added without changing the desktop UI.

## Resource model

- Persistent pool: two logical slots, always available, low guaranteed footprint.
- Workspace pool: three to five logical slots, dynamically divided according to active demand.
- GPU: explicit reservation, not automatic equal partitioning.
- Classroom mode: lowers workspace priority while preserving persistent slots.
- Local-exclusive mode: drains workspace slots before returning GPU and memory capacity to Windows.
