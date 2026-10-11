# Xenomit platform

GitHub-backed, disposable k3d platform for Linux/WSL. GitHub owns repository history;
OpenTofu owns infrastructure; Atlantis plans/applies GitHub PRs; Argo CD owns applications,
fleet specifications, and ephemeral GitHub Actions runner scale sets.

Start with [bootstrap](docs/runbooks/bootstrap.md), [migration](docs/runbooks/migration.md),
the [ownership contract](docs/architecture.md), and the [runbook index](docs/runbooks/README.md).

```bash
git clone https://github.com/xenomit-do/xenomit-platform.git
cd xenomit-platform
bash bootstrap.sh --workspace "$HOME/src/xenomit"
bash verify.sh --workspace "$HOME/src/xenomit"
bash destroy.sh --workspace "$HOME/src/xenomit"
```

Supply credentials outside Git as described in config.example.json. Bootstrap has no dependency on
Atlantis or Argo already existing. All active stacks are listed in infra/stacks.txt; the legacy
root .tf files, bootstrap/, stacks/, and PowerShell entry points are retained for migration reference
and uncommitted local work, and are not used by this bootstrap or Atlantis configuration.

Repository catalog: repositories.json. Applications and runners: xenomit-deployments.
Every organization repository is intended to be public; publication is gated by an audit.
No cluster creation, repository publication, or live apply is performed by local validation.
