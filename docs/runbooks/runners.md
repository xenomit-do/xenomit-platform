# Runner maintenance

Argo applications xenomit-build-runners and xenomit-platform-runners show the ARC scale sets and their
children. Edit min/max runners, image version and resources in xenomit-deployments through PRs.
OpenTofu owns ARC itself, auth Secrets and runner groups. GitHub org Settings > Actions > Runners
shows registration, busy state and group access. Never register individual persistent runners manually.

Build pool uses ephemeral Docker-in-Docker; platform validation has no platform Kubernetes credentials.
Both pools disable service-account token mounting. NetworkPolicy permits DNS/public HTTP(S), excluding
private/LAN/cluster destinations. Do not weaken this for fork jobs. GitHub's fork-ci environment requires
a maintainer approval BEFORE allocating a runner; review the fork's workflow/code first. It receives no
administration credentials. Keep CI tokens read-only and checkout persist-credentials=false.

Jobs target xenomit-build or xenomit-platform explicitly. No ubuntu-latest fallback. Self-hosted compute
does not consume GitHub-hosted minutes. Avoid upload-artifact/cache actions for local build data.
Publishing OCI images to GHCR is separately governed by GitHub Packages limits.

Rotate ARC keys using credential-rotation.md. Rebuild stale runner images regularly. minRunners=1 per
pool makes registration verifiable; reduce to zero only if verification is adapted for idle scale sets.

Runner groups restrict workflow access to the platform reusable checks pinned to protected main, plus main-only image/reconciliation workflows. A fork cannot remove its environment gate by editing a caller workflow: its direct runner jobs are refused. The trusted reusable workflow evaluates the original GitHub PR context and uses the caller repository's fork-ci environment, which requires an authorized maintainer before runner allocation. Never pass secrets with secrets: inherit to source checks.

Publish the trusted reusable workflow files on platform main before applying runner policies and onboarding callers. Required check contexts for reusable calls are source-check / source-check and platform-check / platform-check. Workflow changes require reviewing the trusted main implementation; a PR cannot substitute its own runner-job implementation.
