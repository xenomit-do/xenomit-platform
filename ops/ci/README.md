# Actions runner

`ops/bootstrap.ps1` (via the `xenomit-platform-argocd` stack) installs Application `xenomit-actions-runner` from
`xenomit/xenomit-platform-argocd` at `deploy/runner`. The runner pod is
`xenomit-actions-runner` in namespace `ci`.

That bootstrap does not create a `xenomit-ci` user, a `DEPLOYMENTS_TOKEN`
Actions secret, or Cosign Actions secrets. Image builds stay idle until those
exist. Repository creation and the Argo CD applications are documented in
`../BOOTSTRAP-IAC.md`.
