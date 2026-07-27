# Liaison architecture

## Process model

```text
Windows 11 Pro
├─ LiaisonService.exe                 always on, Rust
│  ├─ loopback JSON control protocol
│  ├─ scheduler and policy engine
│  ├─ host/Tailscale/GPU metrics
│  └─ runtime adapter
├─ Liaison desktop                    optional, Tauri/WebView2
├─ liaison-cli.exe                    optional diagnostics
└─ WSL distribution                   only in real runtime mode
   └─ Docker
      ├─ P1 / P2                      persistent
      └─ W1 ... W5                    workspace
```

The service is the only privileged control component. The GUI is replaceable and may be closed.

## Local protocol

The service accepts one newline-delimited JSON request per TCP connection on a loopback address. The protocol is versioned and limited to 64 KiB per message. It exposes only structured health, snapshot, mode, slot, rebalance, and GPU operations.

## Dynamic resource split

A pool has a fixed capacity; active slots receive an even split including any remainder. For 38 threads: one slot gets 38, two get 19 each, three get 13/13/12, and five get 8/8/8/7/7.

## Operating modes

- **Remote:** full workspace pool and GPU reservations allowed.
- **Class:** active workspaces remain alive using the smaller class pool.
- **Local-exclusive:** all workspace slots stop; P1 and P2 continue.
- **Maintenance:** all managed slots stop.

## Runtime abstraction

`RuntimeAdapter` isolates policy from execution. `MockRuntime` is safe and deterministic. `WslDockerRuntime` invokes Docker inside the configured WSL distribution.

## Persistence

Configuration and the latest state snapshot are JSON files. Container data lives in named volumes. No database process is required.

## GPU behavior

GPU access is a reservation, not perfect hardware partitioning. For WSL Docker, changing access recreates the affected container because Docker cannot add a GPU device to an already-created container.
