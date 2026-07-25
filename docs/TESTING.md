# Testing Liaison

## Fast unit tests

```powershell
cargo test --workspace
```

Coverage includes pool splitting, GPU rules, config validation, protocol serialization, mock runtime lifecycle, client/server behavior, and persistent-slot protection.

## End-to-end smoke test

```powershell
powershell -ExecutionPolicy Bypass -File scripts\smoke-test.ps1
```

This launches `liaison-service` in console mode with `MockRuntime`, drives it through `liaison-cli`, validates JSON responses, then terminates it. It does not call WSL, Docker, Tailscale, or NVIDIA tools.

## GUI test

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run-demo.ps1
```

Expected: P1/P2 autostart, W1–W3 initial demo, 0–5 dynamic split, GPU reservation, Class throttling, and Local-exclusive shutdown of W1–W5 while P1/P2 continue.

## Real WSL Docker test

Only after mock tests pass: prepare the WSL distribution, verify Docker and CUDA, change runtime to `wsl-docker`, start one slot, and verify labels, limits, volumes, stop behavior, and GPU recreation during a maintenance window.
