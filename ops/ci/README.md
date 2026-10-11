# Actions runner

`ops/bootstrap.ps1` (via the `xenomit-platform-argocd` stack) installs Application `xenomit-actions-runner` from
`xenomit/xenomit-platform-argocd` at `deploy/runner`. The runner pod is
`xenomit-actions-runner` in namespace `ci`.

That bootstrap does not create a `xenomit-ci` user or Cosign Actions secrets.
Per-repository `image.yml` workflows on the source repos and digest promotion
in `xenomit-deployments` are documented in `../../docs/runbooks/image-promotion.md`.
Repository creation and the Argo CD applications are documented in
`../BOOTSTRAP-IAC.md`.
