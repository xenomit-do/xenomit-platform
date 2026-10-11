# `.wslconfig` suggestion

Docker Desktop's WSL2 VM takes a default share of host RAM — on a 32 GB machine
that's typically 16 GB, which is inside the platform's *worst-case* budget but
below its comfortable one (docs/11 §11.3: total working set ~12–25 GiB).
Cap it deliberately. `bootstrap-iac.ps1` does not write this file.

Location: `%UserProfile%\.wslconfig` (Windows user profile root, applies to
**all** WSL2 distros). After editing: `wsl --shutdown`, then start Docker
Desktop again.

## If the host has 32 GB RAM (recommended)

```ini
[wsl2]
memory=24GB
processors=10
swap=8GB
localhostForwarding=true
```

Leaves ~8 GB for Windows + browser. The platform's ~25 GiB worst case fits
inside 24 GB with the OS of the VM itself.

## If the host has 16 GB RAM

```ini
[wsl2]
memory=12GB
processors=6
swap=8GB
localhostForwarding=true
```

Tight. Per docs/11 §11.3 you'd additionally want:

- SigNoz with short retention + the aggressive sampling already in
  `ops/k8s/40-otel-collector.yaml` (it's the heaviest single item, 4–6 GiB)
- CI heavy jobs scheduled away from peak bot hours
- Fewer bots than the 50-bot target, or expect OOM kills — measure with the
  phase-1 benchmark before trusting the 64 MiB/bot estimate.

## Notes

- `processors`: the fleet + CI fight for CPU; leaving 2+ cores for Windows
  keeps the box usable while a Rust build runs.
- `localhostForwarding` (default true anyway) keeps `localhost:5000` (registry),
  `:8200` (Vault), `:80/:443` (Traefik) reachable from Windows.
- Docker Desktop's own "Resources" UI sliders write into the same budget — the
  `.wslconfig` cap is what actually bounds the VM.
