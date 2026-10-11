# ops/drills — backup/restore drills (Phase 9, docs/rpo-rto.md)

Backup that has never been restored is a hypothesis, not a backup. These
scripts *perform* the backup, *perform* the restore (into scratch targets so
the live system is never touched), run point checks, and emit a filled
`REPORT.md` next to the artifacts.

| Script | System | Restore target (never live data) | Destructive flag |
|---|---|---|---|
| `drill-postgres.ps1` | `postgres-0` / `xenomit-data` (both DBs) | scratch database `xenomit_drill_<ts>_*`, dropped after | none needed — inherently safe |
| `drill-vault.ps1` | `xenomit-vault` container (Raft) | real `raft snapshot restore` + unseal | `-WithRestore` — overwrites Vault state |
| `drill-gitops.ps1` | gitea `/data` PVC + gitops repo + argo CRs | throwaway gitea repo `gitops-restore-<ts>` | `-WithRestore` — push+delete throwaway |

## Usage

```powershell
.\ops\drills\drill-postgres.ps1 -DryRun   # print the plan, touch nothing
.\ops\drills\drill-postgres.ps1           # dump -> scratch restore -> checks -> report
.\ops\drills\drill-vault.ps1              # snapshot -> inspect -> live checks -> report
.\ops\drills\drill-vault.ps1 -WithRestore # + full restore + unseal (quiesce the fleet first)
.\ops\drills\drill-gitops.ps1 -WithRestore
```

Every script supports `-DryRun` (prints each step — including the exact
commands — without a single kubectl/docker/git mutation), `-WhatIf` via
`SupportsShouldProcess`, and requires only `kubectl` / `docker` / `git` /
`tar` already on PATH. Nothing is installed.

Artifacts + reports land in `ops/drills/out/<system>-<timestamp>/`.
**Copy `out/` off the box after each drill** — an artifact that lives on the
same disk as the PVC doesn't count toward RPO (the report sign-off reminds
you).

## Cadence

Monthly per system (see `docs/rpo-rto.md`), and after any of:
bootstrap changes, Vault image upgrades, k3d cluster rebuild, or a real
restore — a real incident restores under pressure; drills remove the
pressure.

## What is NOT drilled (and why)

- **Postgres PVC itself.** The PVC is k3s local-path — there is no portable
  in-place PV restore. Protection is the logical dump; a lost PVC is rebuilt
  by re-applying the platform Postgres manifest and replaying the latest dump (the drill
  proves exactly that path).
- **Gitea PVC restore.** Same reason — tar exists for forensics/individual
  file recovery. Repository contents are the local `xenomit-platform`,
  `xenomit-platform-gitea`, and `xenomit-platform-argocd` checkouts, which
  `bootstrap.ps1` syncs the checkouts again.
- **cluster-keys.json.** If it's lost AND Vault seals, the data is gone by
  design (Shamir). The drill verifies keys exist and unseal works; storing
  keys off-box is a process control, not a script.
