# argocd/

Manifests and values that `bootstrap/1-services` and `bootstrap/3-tokens` load
with `file()`. Nothing here is applied by hand.

| File | Used by | What it is |
| --- | --- | --- |
| `gitea.yaml` | stage 1 | Gitea Deployment, PVC and Service in namespace `git` |
| `argocd-values-local.yaml` | stage 1 | Helm values for Argo CD (chart version in `bootstrap/1-services/variables.tf`) |
| `atlantis-state.yaml` | stage 1 | Role for the OpenTofu state Secrets in `atlantis-state` |
| `atlantis.yaml` | stage 3 | Atlantis ServiceAccount, PVC, Deployment and Service in `ci` |
| `atlantis-rbac.yaml` | stage 3 | Cluster-wide rights for the `atlantis` ServiceAccount |

The Argo CD AppProject and Applications are OpenTofu resources in
`../../argo.tf`. Delete and bootstrap steps are `../BOOTSTRAP-IAC.md`.
