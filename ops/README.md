# ops/

Scripts that create and delete the local cluster. The procedure, including
the host paths of the PVCs, is `BOOTSTRAP-IAC.md`. URLs and credential
commands are `LOCAL-ACCESS.md`.

Run these from this directory in Windows PowerShell 5.1. Docker Desktop must
already be running.

```powershell
.\teardown.ps1 -RemoveVaultData -Confirm:$false   # delete cluster, PVCs, Vault
.\bootstrap-iac.ps1 -DryRun                        # print the plan
.\bootstrap-iac.ps1                                # create or resume
.\bootstrap-iac.ps1 -Reset                         # delete, then create
```

## Layout

```
bootstrap-iac.ps1        Vault, k3d, Gitea, Argo CD, Atlantis, then OpenTofu
teardown.ps1             deletes the cluster; -RemoveVaultData also deletes Vault
wslconfig.md             suggested %UserProfile%\.wslconfig

k3d/cluster.yaml         k3d cluster xenomit, registry on host port 5000
k3d/localhost-services.yaml
                         NodePorts published on 127.0.0.1 for the local UIs

vault/                   Vault container, init, JWT auth, policies
argocd/                  Gitea, Argo CD Helm values, Atlantis manifests
k8s/12-node-cidr-policies.template.yaml
                         rendered at bootstrap into k8s/rendered/ and applied
provision-api-jwt.ps1    Secret xenomit-system/xenomit-api-jwt
provision-panel-auth.ps1 Secret xenomit-system/xenomit-panel-auth
drills/                  backup and restore drills, not part of bootstrap
```

OpenTofu in the repository root creates namespaces, Postgres, the collector,
OpenObserve, Kyverno, and the Argo CD applications. The orchestrator and panel
manifests are `services/gitops`.
