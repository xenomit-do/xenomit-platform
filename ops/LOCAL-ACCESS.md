# Local cluster access

Last checked: 2026-10-11. Argo CD, OpenObserve, Gitea, PostgreSQL, and the panel
run in the local `xenomit` k3d cluster. They are served by Traefik on port 80
under `*.xenomit.com` names that point at `127.0.0.1` (hosts file), and the load
balancer also publishes a direct loopback port for each, while the cluster is
running, including after Docker Desktop starts again. Vault runs in a local Docker container and serves its UI on port 8200.
How the cluster, repositories, and Argo CD applications are created is
`BOOTSTRAP-IAC.md`. This file is how to open them and read credentials.

## UIs

| Service | URL | Access |
| --- | --- | --- |
| Vault | <https://127.0.0.1:8200/ui/> | Vault uses token login, not username/password accounts. Use the `ops_token` from `ops/vault/cluster-keys.json`; the root token is revoked. The local Vault CA is `ops/vault/tls/ca.crt`. |
| Argo CD | <http://argocd.xenomit.com/> (direct: <http://127.0.0.1:8080/>) | `admin` is the owner; `viewer` is read-only. |
| OpenObserve | <http://openobserve.xenomit.com/> (direct: <http://127.0.0.1:5080/>) | Root login `admin@xenomit.local`. The password is in Secret `observability/openobserve-auth` and Vault KV `secret/infra/openobserve`. |
| Gitea | <http://gitea.xenomit.com/> (direct: <http://127.0.0.1:3000/>) | Log in as `gitops`; get its password from Secret `gitops-git` in namespace `git` below. |
| Xenomit panel | <http://panel.xenomit.com/> (direct: <http://127.0.0.1:3002/>) | The page responds; interactive sign-in needs the panel's Discord OAuth settings. |
| Atlantis | <http://atlantis.xenomit.com/> | No login. It shows plans and locks of the pull requests it handles. |

The names come from the ingress rules in `xenomit-platform/ingress.tf` and are added to
`C:\Windows\System32\drivers\etc\hosts` by `ops/bootstrap.ps1` (which therefore has to run
as administrator). Only missing names are added. If a name does not open, check that the
hosts file has `127.0.0.1 <name>` and that nothing else listens on port 80 (IIS or World Wide
Web Publishing Service). Traffic is plain HTTP; there is no certificate.

OpenLens is installed at `C:\Users\Yagiz\AppData\Local\Programs\OpenLens\OpenLens.exe`.
Open that program and select the `k3d-xenomit` context from `C:\Users\Yagiz\.kube\config`.
The copy in Downloads, `OpenLens.6.5.2-366.exe`, unpacks into `%TEMP%` and then
cannot start `lens-k8s-proxy.exe`. Use the installed program.

`ops/k3d/cluster.yaml` publishes the host ports on the load balancer, and
`ops/k3d/localhost-core.yaml` and `localhost-apps.yaml` are the NodePorts for each
one. Both bind to loopback only. OpenObserve serves the UI and the
OTLP/HTTP ingest API on port 5080.

Gitea holds the private `xenomit` organization. OpenTofu and Atlantis manage
`xenomit-platform`, `xenomit-platform-gitea`, and `xenomit-platform-argocd`.
Argo CD syncs the orchestrator and panel from `services/gitops` in
`xenomit-platform`. How those repositories and applications are created is
`BOOTSTRAP-IAC.md`.

From the host, use the loopback URL. Gitea's canonical URL is cluster-internal,
and that is the URL Argo CD and Atlantis use.

```powershell
git remote add gitea http://127.0.0.1:3000/xenomit/<repo>.git
git push -u gitea HEAD
```

When prompted, use the `gitops` username and password from the Secret below.
Direct pushes to `main` on the three IaC repositories are rejected after
bootstrap; change those through a pull request and `atlantis apply`. Image
digest updates in `services/gitops` use that same pull request.

```powershell
$gitea = kubectl -n git get secret gitops-git -o json | ConvertFrom-Json
[pscustomobject]@{
  username = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($gitea.data.username))
  password = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($gitea.data.password))
}
```

Argo CD reads private repositories with the `xenomit-argocd` user stored in
Secret `argocd/gitea-xenomit-repo-creds`. That user can read
`xenomit-platform` and `xenomit-platform-argocd`.

## GitHub push mirror

After creating the destination repo on GitHub, configure each Gitea repo under
**Settings → Repository → Mirror Settings → Add Push Mirror**. Use the HTTPS
GitHub URL and a GitHub token with write access (`public_repo` for public repos;
`repo` for private repos). Enable **Sync when new commits are pushed** if you
want near-immediate mirroring. Gitea push mirrors force-update the destination,
so keep Gitea as the source of truth. See the [Gitea mirror guide](https://docs.gitea.com/1.25/usage/repository/repo-mirror/).

## Gitea Actions and Argo applications

Application `xenomit-actions-runner` syncs the runner manifests from
`xenomit/xenomit-platform-argocd` at `deploy/runner`. Check it with
`kubectl logs -n ci deploy/xenomit-actions-runner`. The runner is privileged
and uses its own Docker daemon. Jobs publish through `host.k3d.internal:5000`;
pods pull through `xenomit-registry:5000`.

`bootstrap.ps1` does not create the `xenomit-ci` publisher or copy Cosign
material into Gitea Actions secrets. Image builds start after that publisher
exists and a source repository contains `.gitea/workflows/images.yml`.

Argo CD applications on a healthy bootstrap:

| Application | Project | Git path |
| --- | --- | --- |
| `xenomit-control-plane` | `xenomit` | `xenomit-platform` `services/gitops/overlays/local` |
| `xenomit-panel` | `xenomit` | `xenomit-platform` `services/gitops/panel` |
| `xenomit-bots` | `xenomit` | `xenomit-platform` `bots` (renders nothing; sync is denied) |
| `xenomit-actions-runner` | `xenomit-platform-runners` | `xenomit-platform-argocd` `deploy/runner` |

OpenObserve, the collector, Postgres, Kyverno, and the namespaces are applied
by OpenTofu in `xenomit-platform`. They are not Argo CD applications.

Retrieve the OpenObserve root password:

```powershell
$oo = kubectl -n observability get secret openobserve-auth -o json | ConvertFrom-Json
[pscustomobject]@{
  email    = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($oo.data.email))
  password = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($oo.data.password))
}
```

The same values are in Vault KV `secret/infra/openobserve`. Atlantis and
Argo CD service tokens are listed at the end of this file.

Retrieve Argo CD `admin` and `viewer` passwords. `xenomit-tofu` is an API
token only; it is in Secret `ci/atlantis-iac`.

```powershell
$accounts = kubectl -n argocd get secret argocd-local-accounts -o json | ConvertFrom-Json
[pscustomobject]@{
  admin  = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($accounts.data.'admin-password'))
  viewer = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($accounts.data.'viewer-password'))
}
```

Retrieve the Vault UI token without putting it in this document:

From the `xenomit-platform` directory:

```powershell
(Get-Content .\ops\vault\cluster-keys.json -Raw | ConvertFrom-Json).ops_token
```

## Accounts and persistence

Machine or Docker daemon restarts preserve the data below when the same Docker
volumes remain available. The services use restart policies, so their
containers/pods are expected to come back; this is local disk persistence, not
an off-machine backup.

| Service | Accounts / identity | Persistent data and credentials |
| --- | --- | --- |
| Gitea | Admin login: `gitops`. Repositories belong to the `xenomit` organization. `atlantis` is an organization owner and the Atlantis merge account. `xenomit-argocd` is the read-only Argo CD user. | Users, password hashes, organizations, and repositories live in Gitea's SQLite database on PVC `git/gitea-data` (1 GiB). The `gitops` password is also in Secret `git/gitops-git`. Atlantis tokens are in `ci/atlantis-vcs`. |
| OpenObserve | Root login `admin@xenomit.local`. Retrieve the password from Secret `observability/openobserve-auth` key `password`, or from Vault KV `secret/infra/openobserve`. | Telemetry is stored on PVC `observability/openobserve-data` (10 GiB) and retained for seven days. The collector pods are stateless, so in-flight batches can be lost on restart. |
| Vault | Token authentication, not user/password accounts. The `ops_token` is the operator login; the root token was revoked. Workloads authenticate through Vault's Kubernetes JWT auth role. | Vault policies, auth configuration, and KV secrets are in integrated Raft storage on Docker named volume `xenomit-vault_vault-data`. The unseal shares and `ops_token` are also saved in `ops/vault/cluster-keys.json` on the host. |
| PostgreSQL | Database role `xenomit`. | Role catalog and database files are on PVC `xenomit-data/data-postgres-0`. Secret `xenomit-data/postgres-auth` holds the connection password; bootstrap also stores it at Vault KV `secret/infra/postgres` when Vault is available. |

For the panel, Vault KV `secret/infra/panel-auth` is now the source of truth
for the 256-bit Auth.js `AUTH_SECRET`; bootstrap imports the current
Kubernetes value on first run to preserve active sessions. Kubernetes Secret
`xenomit-system/xenomit-panel-auth` is a runtime mirror for the pod, not the
only copy.

The Kubernetes PVCs are directories inside the k3d server's Docker volume,
mounted in the node at `/var/lib/rancher/k3s/storage`. On this Windows host
that volume is:

`\\wsl$\docker-desktop\mnt\docker-desktop-disk\data\docker\volumes\3538924d7481bd9f27aceebe017d7da3d8fa2eceba7e307996239a614ba48a4b\_data\storage`

| PVC | Directory under that `storage` folder |
| --- | --- |
| `git/gitea-data` | `pvc-8e60e81d-8731-4f29-b229-28740fdf2040_git_gitea-data` |
| `xenomit-data/data-postgres-0` | `pvc-3cf9e0fa-61a1-4a7f-b4f8-1773afbacd75_xenomit-data_data-postgres-0` |
| `observability/openobserve-data` | `pvc-4f7203a7-541d-4515-bd74-acb01eac7337_observability_openobserve-data` |
| `ci/atlantis-data` | `pvc-4a2fe5c8-f331-48da-9e4b-4b64108e2acd_ci_atlantis-data` |
| `ci/xenomit-actions-runner-data` | `pvc-38496799-d2dc-45f3-829e-ead2bc047700_ci_xenomit-actions-runner-data` |
| `ci/xenomit-actions-docker-data` | `pvc-e12ad845-9073-45d0-b0fe-72d6ed9e7538_ci_xenomit-actions-docker-data` |

The registry data is `\\wsl$\docker-desktop\mnt\docker-desktop-disk\data\docker\volumes\dcd8535e57d22594c32443d57bb72fdb0ce4ac546702ad353e1cdfaa4d2736d0\_data`.
The k3d image volume is `\\wsl$\docker-desktop\mnt\docker-desktop-disk\data\docker\volumes\k3d-xenomit-images\_data`.
Those ids change when the cluster is created again. `ops/BOOTSTRAP-IAC.md`
has the delete commands and how to read the new paths from `teardown.ps1`.

The local-path reclaim policy is `Delete`. Vault's named volume is
independent of the k3d cluster:

`\\wsl$\docker-desktop\mnt\docker-desktop-disk\data\docker\volumes\xenomit-vault_vault-data\_data`

A cluster rebuild alone does not remove that directory. `teardown.ps1
-RemoveVaultData` does, and it also deletes
`C:\Users\Yagiz\Desktop\repos\xenomit-platform\ops\vault\cluster-keys.json`.

## PostgreSQL

The PostgreSQL Service is in namespace `xenomit-data`. Connect to
`127.0.0.1:5433`, database `xenomit`, user `xenomit`. The host's port 5432 is
already used by a local PostgreSQL process, so this cluster is published on
5433.

Retrieve the current username and password from the cluster Secret:

```powershell
$pg = kubectl -n xenomit-data get secret postgres-auth -o json | ConvertFrom-Json
[pscustomobject]@{
  username = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pg.data.POSTGRES_USER))
  password = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pg.data.POSTGRES_PASSWORD))
}
```

The credentials are intentionally not stored in this file. OpenTofu generates
the password once and keeps it in the `xenomit-platform` state. A later apply
does not rotate it.

## Registry and panel image

The host pushes to `localhost:5000`; pods pull through
`xenomit-registry:5000`. Workload images are pinned by digest and must pass the
Cosign signature policy in `manifests/policies`.
An all-zero digest is a bootstrap placeholder, not a usable image. Keep the
signature policy enforced when publishing a replacement.

The encrypted local signing key and its passphrase are held in Vault at
`secret/infra/cosign-signing` when that path has been populated; only its
public key belongs in the repository. `bootstrap-iac.ps1` does not copy the
private key into Gitea Actions secrets.

## After a fresh bootstrap

`xenomit-control-plane` and `xenomit-panel` stay unready until digest-pinned,
signed images exist in `xenomit-registry:5000`. Kyverno rejects a placeholder
digest. OpenObserve, the collector, Postgres, Gitea, Argo CD, and Atlantis
do not use that registry.

Panel Auth.js material is Vault KV `secret/infra/panel-auth`, mirrored to
Secret `xenomit-system/xenomit-panel-auth`. The API signing keys are Secret
`xenomit-system/xenomit-api-jwt`.

The collector's `redaction` processor is on the traces pipeline only. Metrics
and logs use the transform processor, then OTLP/HTTP to OpenObserve.

## Service Secrets

Atlantis and the OpenTofu providers read these Secrets. They are not UI logins. Print a
value only in the shell session that needs it.

| Secret | Keys |
| --- | --- |
| `ci/atlantis-vcs` | `ATLANTIS_GITEA_USER`, `ATLANTIS_GITEA_TOKEN`, `ATLANTIS_GITEA_WEBHOOK_SECRET` |
| `ci/atlantis-iac` | `ARGOCD_AUTH_TOKEN` for the `xenomit-tofu` account |
| `ci/atlantis-mirror` | `GITHUB_MIRROR_USERNAME`, `GITHUB_MIRROR_TOKEN`, copied from Vault `secret/infra/github-mirror` (only with a token file) |
| `git/gitea-service-users` | passwords of the `atlantis` and `xenomit-argocd` Gitea users and the webhook secret |
| `argocd/gitea-xenomit-repo-creds` | Argo CD repo credential for `http://gitea.git.svc.cluster.local:3000/`, user `xenomit-argocd` |
| `xenomit-system/xenomit-panel-auth` | `AUTH_SECRET`, also Vault `secret/infra/panel-auth` |
| `xenomit-system/xenomit-api-jwt` | `jwt-private.pem`, `jwt-public.pem`, `service-token` |

```powershell
$s = kubectl -n git get secret gitops-git -o json | ConvertFrom-Json
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s.data.password))   # same pattern for any key above
```

The bootstrap also keeps every generated password in its local OpenTofu state,
`bootstrap/*/terraform.tfstate` and `stacks/*/terraform.tfstate`, for example
`tofu -chdir=../bootstrap/1-services output`.
That state is deleted by `teardown.ps1`.
