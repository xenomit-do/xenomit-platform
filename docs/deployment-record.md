# Deployment and migration record — 2026-10-11

## Running environment

The native Linux workspace is `/home/yagiz/src/xenomit` in Ubuntu WSL. The `xenomit` k3d cluster uses context `k3d-xenomit`; its private kubeconfig is `.xenomit/kubeconfig` under that workspace. Windows originals remain preserved.

All five OpenTofu stacks were applied: identity, external resources, controllers, services and Vault. Kubernetes-backed state and locking are shared with Atlantis in `atlantis-state`. GitHub and Cloudflare resources remain persistent; use the discovery/import recovery runbook when replacing a cluster.

Argo CD, Atlantis, Cloudflare connector, ARC, Kyverno, Vault, PostgreSQL, OpenObserve and the telemetry collector were healthy. The build and platform runner pools registered and executed CI on ephemeral self-hosted runners. Argo runner and fleet Applications were Synced/Healthy against `xenomit-deployments/main`. Runner version is 2.338.0.

## Live acceptance evidence

- All 24 catalog repositories are public, have automatic PR head deletion enabled and share the managed default-branch policy: PRs, strict required checks, resolved conversations, administrator enforcement, no force pushes or branch deletion, and zero mandatory human reviews.
- CI onboarding PRs merged after checks on managed runners. Source migration PRs preserve surviving ancestry without force-overwriting GitHub history; repositories without surviving commits received audited source imports.
- [Platform PR #1](https://github.com/xenomit-do/xenomit-platform/pull/1) completed Atlantis plan, apply and automerge. [Deployments PR #1](https://github.com/xenomit-do/xenomit-deployments/pull/1) upgraded the runner images; merged Applications reconcile main.
- `https://atlantis.xenomit.com/` returned 404; `/events` rejected an invalid signature with 400. The public tunnel routes only the webhook endpoint. The UI remains local.
- Final platform verification passed. Local checks passed all five pinned-provider validations, formatting/ShellCheck, 13 Python tests and the OpenTofu ownership mock test.

## Migration safeguards

Private inventory, publication scan reports and migration PR records are stored in `.xenomit/`. Full surviving history and staged source passed secret scans before publication. Windows worktrees and private runtime files were not overwritten. Private game captures, downloaded runtime assets, databases, session tokens and credentials were excluded; proprietary Flash/Pepper binaries are supplied locally. The raylib fixture requirements are documented in that repository.

Application source imports retain the managed source-check workflow. That check verifies whitespace and secret scanning; it does **not** prove that every application compiles or builds an image. Former GitHub-hosted workflows are preserved in historical commits but are replaced in the active migration tree. Deleted Gitea PR history cannot be restored without backups.

External credentials are stored only in `/home/yagiz/.config/xenomit` (directory 0700; credential files 0600). Generated cluster state and credentials live in private `.xenomit/` files. Never commit either directory or copy credentials into this documentation. Rotate any previously exposed credentials before reuse.

## Outstanding acceptance work

Bot control-plane and panel deployment remains disabled (`enable_applications=false`); the fleet is empty until real application images are built and digest-pinned. End-to-end image build/sign/pull/promotion has not been exercised. The original orchestrator workspace declares a missing `e2e` member; earlier Rust validation used an isolated copy without that member.

A destructive teardown/rebuild and reproduction on a second machine have not been exercised. Use the recovery and machine migration runbooks, transferring only externally supplied credentials and the committed configuration. Stop the old environment and release its active-environment lease before starting the new tunnel. Databases, bot runtime state and generated passwords are disposable.

## Routine operation

From the Linux platform checkout, use `./bootstrap.sh`, `./verify.sh` and `./destroy.sh` as documented in `docs/runbooks/`. Bootstrap preserves dirty or divergent worktrees and reports them. Apply repository/catalog changes through a protected PR; Atlantis owns the apply path, with host applies reserved for documented Atlantis self-upgrades. Argo owns runner scale sets and application/fleet manifests; the operator owns only bot resources derived from fleet specifications.

Do not manually add permanent repositories, runner configuration or Argo registrations. Follow repository onboarding so the catalog derives protection, integrations, CI access and workspace inclusion together.
