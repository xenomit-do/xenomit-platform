# Xenomit platform

OpenTofu definition of the Xenomit cluster platform. Atlantis applies changes from pull requests. `ops/bootstrap.ps1` builds the cluster and applies the OpenTofu stacks listed in `ops/stacks.txt`, in order, until the platform is complete; `bootstrap/` holds the minimal structure (Gitea, Argo CD, Atlantis) and `stacks/` the admin stacks.

This stack creates the workload namespaces, network baseline, Postgres, the collector, OpenObserve, fleet CRDs, Kyverno, and the Argo CD project that deploys the orchestrator and the panel from `services/gitops`. Gitea, Argo CD, and Atlantis themselves are installed by `bootstrap/` because they have to exist before this stack can run.

The orchestrator binary is built from `xenomit-orchestrator`. This repository owns how that binary runs on the cluster.

Bootstrap, teardown, and a step-by-step explanation of the pipeline are in `ops/BOOTSTRAP-IAC.md`. Local URLs and credential commands are in `ops/LOCAL-ACCESS.md`.

## Layout

| Path | What it is |
| --- | --- |
| `bootstrap/` | The minimal working structure: Gitea, Argo CD, tokens and Atlantis (three OpenTofu stages) |
| `stacks/` | Admin OpenTofu applied by the bootstrap after the platform stacks: other repositories and their mirrors, GitHub token, post-apply secrets |
| `ops/` | Bootstrap and teardown scripts, Vault, k3d config, and the manifests `bootstrap/` and `stacks/` load |
| `services/gitops/` | Kustomize manifests for the orchestrator and the web panel |
| `services/docker/` | Dockerfiles for the panel and the packet updater |
| `db/plans/` | SQL for plan, quota, and billing tables |
| `manifests/` | Namespaces, platform services, CRDs, and Kyverno policies applied by OpenTofu |
| `observability/` | Dashboard and alert definitions |
| `ci/workflows/` | Image, panel, updater, and nightly workflows |
