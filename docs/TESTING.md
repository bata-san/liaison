# Testing Liaison

## Fast unit tests

```powershell
cargo test --workspace
```

Coverage includes:

- exact preservation of pool capacity during 1–5-way splits;
- GPU reservation rules;
- config safety validation;
- request serialization;
- mock runtime lifecycle;
- authenticated client/server behavior;
- Local-exclusive protection of persistent slots.

## End-to-end smoke test

```powershell
powershell -ExecutionPolicy Bypass -File scripts\smoke-test.ps1
```

This launches `liaison-service` in console mode with `MockRuntime`, drives it through `liaison-cli`, validates JSON responses, then terminates the process.

The test is safe on a normal developer PC because it does not call WSL, Docker, Tailscale, or NVIDIA tools.

## GUI test

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run-demo.ps1
```

Expected result:

- P1 and P2 start automatically;
- W1–W3 start in the initial demo;
- selecting 0–5 changes the workspace split;
- GPU reservation is visible on a running workspace;
- Class mode throttles running workspace slots;
- Local-exclusive stops W1–W5 and keeps P1/P2 running;
- stopping the GUI also stops the temporary demo service.

## Real WSL Docker test

Only perform this after mock tests pass.

1. Prepare the configured WSL distribution and install Docker Engine inside it.
2. Confirm `wsl.exe -d LiaisonRuntime -- docker version` succeeds.
3. Confirm NVIDIA CUDA works in WSL before enabling GPU reservations.
4. Change `runtime` to `wsl-docker` in the config.
5. Start one workspace slot first.
6. Verify container labels, memory limits, named volumes, stop behavior, and GPU recreation.

Use a maintenance window because real runtime testing creates and stops containers.
