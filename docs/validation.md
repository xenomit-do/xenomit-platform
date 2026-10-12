# Current live validation

See [deployment and migration record](deployment-record.md) for the live bootstrap evidence and remaining acceptance work. The local implementation notes below predate the live deployment.

# Implementation validation

Validated locally on 2026-10-11:

- OpenTofu 1.12.6: all five active stacks initialized without a backend and validated against their pinned provider schemas; recursive formatting passes.
- Mock provider plan: default runner/fleet Applications and fleet-only Argo resource ownership pass.
- Python: 13 tests pass for publication attestations, recovery imports, owner exclusion/reentry, catalog coverage, dirty checkout preservation, trusted workflow boundaries and onboarding idempotence.
- Linux/WSL: Bash syntax and ShellCheck 0.10.0 pass.
- Helm 3.18.6: both pinned ARC dependency charts build and render; Argo/Vault chart versions resolve. Control-plane and panel Kustomize manifests render. Active YAML/workflow files parse.
- Rust: two API GitOps boundary tests and nine Argo tracking tests pass. orchestratord compiles with status-only writes and Git-owned deletion guards.

Rust validation used an isolated copy excluding the original missing e2e workspace member. The source workspace manifest was preserved. The local orchestrator directory has no Git metadata, so history must be recovered or its surviving source imported before migration.

Not exercised: live GitHub/Cloudflare import and publication, real image builds/signing/pulls, runner registration, signed webhook delivery, Atlantis plan/apply/automerge, cluster teardown/rebuild and migration to another machine. Complete those acceptance drills with external credentials/domain and committed sources. No GitHub pushes, public visibility changes, archival, or live cluster applies were performed during local implementation.

Existing legacy local edits were preserved. GitHub history/publication and retiring old repositories are explicit operations, not consequences of running local tests.
