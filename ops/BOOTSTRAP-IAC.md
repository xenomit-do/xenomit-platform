# Local platform: bootstrap, stacks, teardown

The platform is rebuilt from git. On a new machine you clone `xenomit-platform` from GitHub and run
one script. It builds the **minimal working structure** (Vault, a k3d cluster, Gitea, Argo CD,
Atlantis) and then applies OpenTofu **stacks** from the repositories, in order, until the platform is
in the same state as the machine you left. A change to the platform is a change to a stack in git.
It is never a change to the script.

- [Quick start](#quick-start)
- [A new machine](#a-new-machine)
- [Teardown](#teardown)
- [How it works](#how-it-works)
- [Stacks](#stacks)
- [Making a change](#making-a-change)
- [Atlantis scope](#atlantis-scope)
- [Repositories outside Atlantis](#repositories-outside-atlantis)
- [GitHub mirrors](#github-mirrors)
- [Re-running and failure recovery](#re-running-and-failure-recovery)
- [Day 2: changing the platform](#day-2-changing-the-platform)
- [Local run after a reboot](#local-run-after-a-reboot)

## Quick start

Prerequisites on `PATH`: `docker` (Docker Desktop running), `kubectl`, `k3d`, `git`, **`tofu`**
(OpenTofu 1.10 or newer, `winget install OpenTofu.Tofu`). `helm` is not needed. The script installs nothing.

Run it from an **elevated PowerShell** (Run as administrator). The UIs are served on names such as
`argocd.xenomit.com`, and the script adds the names that are missing to the Windows hosts file.

```powershell
cd <folder that holds the checkouts>\xenomit-platform\ops
.\bootstrap.ps1            # create or resume, safe to run again
.\bootstrap.ps1 -Reset     # from scratch: tear down first, then build
```

The URLs, and where each password is kept, are in `LOCAL-ACCESS.md`.

## A new machine

1. Install the prerequisites above and start Docker Desktop.
2. Make a folder for the checkouts and clone the one repository that holds the script:

   ```powershell
   mkdir C:\src\xenomit; cd C:\src\xenomit
   git clone https://github.com/xenomit-do/xenomit-platform.git
   ```

3. Put the GitHub token next to it, in a file called `github pat.txt` (one line, the token). It is never
   in git. The token is used to clone the other repositories, and it is stored in Vault for the mirrors
   and releases (see [GitHub mirrors](#github-mirrors)).
4. Open PowerShell as administrator and run the script:

   ```powershell
   cd xenomit-platform\ops
   .\bootstrap.ps1
   ```

The script clones the repositories listed in `repos.txt` from `https://github.com/xenomit-do/<name>`
that are missing, builds the minimal structure, pushes the checkouts into Gitea, and applies every
stack in `stacks.txt`. When it ends the platform is configured as before: the same Gitea
organization, repositories, branch protection, mirrors, Atlantis with its limited access, Argo CD
applications, runner, databases and policies.

What does not come back by itself, because it is not in git: the contents of Vault other than what the
stacks write (a fresh Vault is initialised, with new unseal keys in `ops/vault/cluster-keys.json`),
Postgres and OpenObserve data, container images that were never pushed to the registry, and the Pepper
plugin (`runtime/libpepflashplayer.so`).

## Teardown

```powershell
cd <checkouts>\xenomit-platform\ops
.\teardown.ps1 -RemoveVaultData -Confirm:$false   # everything, including Vault
.\teardown.ps1                                    # cluster only; Vault data and unseal keys stay
```

Both print the host paths first, then delete:

| What | Default | With `-RemoveVaultData` |
| --- | --- | --- |
| k3d cluster `xenomit`: server, load balancer, registry, `k3d-xenomit-images`, and the volume that holds every PVC (Gitea, Postgres, OpenObserve, Atlantis, Actions runner) | removed | removed |
| State of the platform stacks (Secrets in namespace `atlantis-state`) | removed with the cluster | removed |
| Local state of `bootstrap/*` and `stacks/*` (`terraform.tfstate*`, it holds generated passwords and tokens) | removed | removed |
| Vault container `xenomit-vault` | removed | removed |
| Vault Raft volume `xenomit-vault_vault-data` and `ops/vault/cluster-keys.json` | kept | removed |
| `ops/vault/tls`, downloaded providers in `.terraform` | kept | kept |

The k3s volume id and the `pvc-*` names change with every cluster, so the script prints the live paths.
To confirm a clean slate:

```powershell
k3d cluster list                                  # no xenomit row
docker ps -a --filter name=xenomit                # nothing
docker volume ls --filter name=xenomit            # nothing after -RemoveVaultData
```

`-Reset` on `bootstrap.ps1` is `teardown.ps1 -RemoveVaultData` followed by a bootstrap.

## How it works

`bootstrap.ps1` does three things and knows nothing about what the platform contains:

1. **Prepares the machine**: clones missing repositories from GitHub, starts Vault, creates the k3d cluster.
2. **Applies the stacks in `stacks.txt`, in order.** The first three (`bootstrap/*`) are the minimal
   structure. The rest are the platform itself, declared as OpenTofu in git.
3. **Pushes checkouts to Gitea** whenever a stack lists them in its `seed_repositories` output.

```
 host (PowerShell + tofu)                                    k3d cluster (Docker)
 ─────────────────────────                                   ────────────────────
 0  clone missing repositories from GitHub  (repos.txt)
    vault-init.ps1  ──────────────────────────────────────►  Vault runs in Docker, outside k3d
    k3d cluster create  ──────────────────────────────────►  node + load balancer, ports published
    vault-configure-jwt.ps1  ─────────────────────────────►  Vault trusts the cluster's SA tokens

 ── minimal structure (bootstrap/) ───────────────────────────────────────────────────────────────
 1  bootstrap/1-services   namespaces, passwords, Secrets, Gitea (+ admin), Argo CD, loopback ports
 2  bootstrap/2-seed       org xenomit, users atlantis + xenomit-argocd, the 3 platform repos (empty)
    └─ output seed_repositories ──► push the 3 checkouts to Gitea
 3  bootstrap/3-tokens     Gitea + Argo CD tokens, Secrets, runner token, Atlantis

 ── the platform, as OpenTofu in git ─────────────────────────────────────────────────────────────
 4  stacks/10-github-token    GitHub token into Vault, Secret ci/atlantis-mirror for Atlantis
 5  xenomit-platform          namespaces, network baseline, Postgres, OpenObserve, collector, CRDs,
                              Kyverno, Argo project + applications          (state in the cluster)
 6  xenomit-platform-gitea    team, Atlantis membership, webhooks, branch protection, mirrors
 7  xenomit-platform-argocd   Actions runner, platform applications in Argo CD
 8  stacks/30-gitea-extra     other repositories, protection, mirrors, release secrets
    └─ output seed_repositories ──► push those checkouts to Gitea
 9  stacks/90-post            Vault CA, database URLs, Vault KV, node-CIDR policies, app ports
    provision-panel-auth.ps1, provision-api-jwt.ps1
```

Steps 5 to 7 are the same directories Atlantis plans for pull requests. The first apply runs from the host,
the state is a Secret in the cluster (`atlantis-state`), and Atlantis takes over from there.

### The minimal structure, step by step

**`bootstrap/1-services`** needs only `kubectl`. It creates the namespaces `git`, `argocd`, `ci`,
`atlantis-state`; generates every password with `random_password` and stores them as Secrets
(`git/gitops-git`, `git/gitea-service-users`, `argocd/argocd-local-accounts`); applies `ops/argocd/gitea.yaml`;
creates the `gitops` admin inside the Gitea pod (`gitea-admin.sh`, the one thing the Gitea API cannot do,
because the first admin has to come from the command line); installs Argo CD as a `helm_release` with the bcrypt
hashes of the admin and viewer passwords in the chart values; and publishes Gitea and Argo CD on loopback
through two NodePort Services, so the host can reach both APIs from here on.

**`bootstrap/2-seed`** talks to the Gitea API from the host as `gitops`. It creates the organization
`xenomit`, the users `atlantis` and `xenomit-argocd` (neither is an organization owner), and the three
platform repositories **empty**, so they can receive their first commit. It deliberately does not manage
their settings: that belongs to `xenomit-platform-gitea`, which imports them later (`ignore_changes = all`).
Its `seed_repositories` output makes the script push the three checkouts to Gitea.

**`bootstrap/3-tokens`** is separate from stage 2 on purpose: the Gitea provider logs in when it is
configured, and a Gitea token can only be issued by the user it belongs to, so the aliases for `atlantis`
and `xenomit-argocd` can only be configured after stage 2 created those users. It mints a token for each
(Atlantis: repository, organization and issue scopes; Argo CD: read only), an admin token for the applies
that run from the host, and an Argo CD API token for the account `xenomit-tofu`. It writes the Secrets that
consume them (`ci/atlantis-vcs`, `ci/atlantis-iac`, `argocd/gitea-xenomit-repo-creds`), the runner
registration token (`ci/xenomit-actions-runner-token`; without it the runner pod never starts and no
workflow runs), and deploys Atlantis with its cluster role. Atlantis starts with its tokens in place but
has no repository access yet: it gets that from the `xenomit-platform-gitea` stack.

## Stacks

`stacks.txt` is the ordered list. Each line is `<state> <path>`:

- `local`: the state is a file next to the stack. Used for `bootstrap/*` and the admin stacks in `stacks/`.
  It is disposable together with the cluster (`teardown.ps1` deletes it).
- `cluster`: the state is a Secret in the cluster, so Atlantis can take over. Used for the three platform
  repositories. The script reaches that Secret through the kubeconfig
  (`-backend-config in_cluster_config=false`), Atlantis through its ServiceAccount: it is the same state.

**How a stack gets its variables.** The script keeps a context of named values. It starts with the loopback
addresses, the kubeconfig, the node facts and the GitHub token file, and after every stack it adds every output of
that stack. Before a stack runs, each variable the stack declares that the context knows is passed in
(`TF_VAR_<name>`). So a stack that needs the Gitea admin token declares `variable "gitea_token"`, and the output
`gitea_token` of `bootstrap/3-tokens` arrives. Nothing in the script mentions a particular resource. The defaults of
those variables are the in-cluster values, which is why the same code runs unchanged under Atlantis.

**Seeding.** A stack that creates repositories outputs `seed_repositories`. Right after it, the script pushes
those local checkouts to Gitea (remote `gitea`, branch tracking `gitea/main`). Pending changes in a checkout
are committed first, because Argo CD and Atlantis read what is in Gitea. Secrets and state files are refused.

| Stack | Applied by | Contents |
| --- | --- | --- |
| `bootstrap/1-services` | bootstrap | namespaces, passwords, Gitea, Argo CD, loopback ports |
| `bootstrap/2-seed` | bootstrap | org, users, platform repositories (empty) |
| `bootstrap/3-tokens` | bootstrap | tokens, Secrets, runner token, Atlantis |
| `stacks/10-github-token` | bootstrap | GitHub token in Vault and for Atlantis |
| `xenomit-platform` | bootstrap, then Atlantis | cluster platform |
| `xenomit-platform-gitea` | bootstrap, then Atlantis | Gitea settings of the platform repositories |
| `xenomit-platform-argocd` | bootstrap, then Atlantis | runner, Argo CD applications |
| `stacks/30-gitea-extra` | bootstrap | repositories Atlantis must not reach |
| `stacks/90-post` | bootstrap | Vault CA, database URLs, Vault KV, node-CIDR policies, app ports |

## Making a change

You never edit `bootstrap.ps1`.

- **A platform resource** (a namespace, a policy, a deployment): edit `xenomit-platform`, open a pull request,
  Atlantis plans it. See [Day 2](#day-2-changing-the-platform).
- **A Gitea setting of a platform repository** (protection, webhook, mirror): edit `xenomit-platform-gitea`.
- **An Argo CD application**: edit `xenomit-platform-argocd`.
- **A repository that Atlantis must not reach**, its protection, mirror or Actions secret: edit
  `stacks/30-gitea-extra` (`extra_repositories`, `github_mirrors`, `release_secret_repositories`), and add the
  repository's name to `repos.txt` so a new machine clones it.
- **Something new that does not fit** (another admin step): add a directory under `stacks/` with its OpenTofu,
  and a line to `stacks.txt` at the right position. If it needs a value from an earlier stack, declare a
  variable with the output's name. If it creates repositories, output `seed_repositories`.

Changes in `bootstrap/` and `stacks/` are applied by re-running `.\bootstrap.ps1`, or one stack by hand:
`tofu -chdir=..\stacks\30-gitea-extra apply`. Changes in the three platform repositories are applied by
Atlantis after the pull request, and by the script on a new machine.

## Web UIs

The UIs open on names without a port: `argocd.xenomit.com`, `gitea.xenomit.com`, `openobserve.xenomit.com`,
`panel.xenomit.com`, `atlantis.xenomit.com`.

- The k3d load balancer publishes ports 80 and 443 on `127.0.0.1` only (`ops/k3d/cluster.yaml`) and
  forwards them to Traefik, the ingress controller built into k3s. Traefik routes by the `Host` header.
- The routes are Kubernetes `Ingress` objects declared in OpenTofu, in `xenomit-platform/ingress.tf` (a map from
  name to namespace, Service and port). To add a UI, add a line there and open a pull request.
- The stack outputs the full names as `hostnames`. After the stacks, `bootstrap.ps1` reads every `hostnames`
  output and adds the names that are missing to `C:\Windows\System32\drivers\etc\hosts` as
  `127.0.0.1 <name>`, under a comment. An existing entry is never changed; if a name already points elsewhere
  the script prints a warning. This is why the script needs administrator rights, and it is the only part of the
  routing that is not OpenTofu: a hosts file cannot be declared in the cluster.
- The direct loopback ports (Argo CD 8080, Gitea 3000, OpenObserve 5080, panel 3002, Postgres 5433) stay,
  because the bootstrap talks to Argo CD and Gitea through them before any hosts entry or ingress exists.
- Plain HTTP only. The names are under `xenomit.com`, so on this machine they hide the real hosts of that
  domain with the same names. `teardown.ps1` leaves the hosts file alone; remove the block marked
  "Xenomit local platform" by hand if you want it gone.

## Atlantis scope

Atlantis may reach the three platform repositories (`xenomit-platform`, `xenomit-platform-gitea`,
`xenomit-platform-argocd`) and nothing else:

- Its repository allowlist (`ATLANTIS_REPO_ALLOWLIST` in `ops/argocd/atlantis.yaml`) lists only those three.
- Its Gitea access comes from the team `platform-infra`, which has admin on those three repositories only
  (`include_all_repositories = false`). The `xenomit-platform-gitea` stack creates the team and puts
  `atlantis` in it.
- `atlantis` is **never** an organization owner (Owners can reach every repository). The first apply of
  `xenomit-platform-gitea` runs from the host with the admin token, so Atlantis does not need owner rights to
  create the team. Atlantis's own token only has the scopes it needs.

Repository and team creation is therefore not something Atlantis does for new repositories.

## Repositories outside Atlantis

Other repositories of the organization are in `stacks/30-gitea-extra`, applied with the `gitops` admin, so
Atlantis never has access to them:

| Repository | Purpose | `main` | Argo CD read access |
| --- | --- | --- | --- |
| `xenomit-flash-client-linux` | Linux Pepper Flash host used by the bots | pull requests only | no |
| `xenomit-deployments` | deployment sources that Argo CD syncs from | not protected yet (CI will promote digests into it) | yes |

On a protected `main` only the `gitops` admin may push directly (a push whitelist). That is how a new machine
seeds the repository before anyone else can change it. Everyone else goes through a pull request.

### Flash client CI

`xenomit-flash-client-linux` has Gitea Actions workflows (runner label `xenomit`):

- `ci.yml`, on every pull request: shellcheck, `node --check`, cmake configure (lint), then the native build with
  its ctest suite, the browser host tests and packaging. The tarball is a workflow artifact.
- `release.yml`, on every merge to `main`: the same, then publishes
  `xenomit-flash-client-linux-<version>-<commit>-linux-x64.tar.gz` and its `.sha256` as a Gitea workflow artifact
  and, because the repository has the Actions secret `RELEASE_GITHUB_TOKEN`, as a GitHub Release of
  `xenomit-do/xenomit-flash-client-linux`.

Other projects can then import a pinned, versioned build from GitHub instead of a locally managed copy. The
GitHub repository must exist and have at least one commit (the mirror provides that). The scripts in
`scripts/ci/` run the same steps locally. Not done yet: the reflection-bridge injector needs the sibling
`xenomit-flash-client` checkout and is skipped in CI (`injector_included` is `false` in `MANIFEST.json`).

## GitHub mirrors

Gitea mirrors repositories to GitHub itself, as *push mirrors*: every branch and tag is pushed under its own
name on each commit and at least every 8 hours. A push mirror makes the GitHub repository match Gitea exactly, so
branches that exist only on GitHub are removed. That is what lets a new machine clone from GitHub and reach the
latest state.

**One URL per repository.** The platform repositories have a map in `xenomit-platform-gitea/mirror.tf`, the other
repositories in `stacks/30-gitea-extra` (`github_mirrors`):

```hcl
github_mirrors = {
  "xenomit-platform"        = "https://github.com/xenomit-do/xenomit-platform.git"
  "xenomit-platform-gitea"  = "https://github.com/xenomit-do/xenomit-platform-gitea.git"
  "xenomit-platform-argocd" = "https://github.com/xenomit-do/xenomit-platform-argocd.git"
}
```

Each entry is one push mirror (a `restapi_object` calling Gitea's API, because the Gitea provider has no
resource for it). All mirrors share one token.

**Where the token lives.** Gitea cannot read Vault, and Atlantis has no access to Vault. Vault is where the
token is kept and rotated, and `stacks/10-github-token` carries it to where it is needed:

```
github pat.txt --> Vault secret/infra/github-mirror {username, token}
                      |  read back by stacks/10-github-token
                      +--> Secret ci/atlantis-mirror --> Atlantis env TF_VAR_github_mirror_token
                      |        (mirrors of the platform repositories, day 2)
                      +--> output github_mirror_token --> stacks/30-gitea-extra and xenomit-platform-gitea
                               (the first apply from the host)
```

- Without `github pat.txt`, the token variable is null and no mirror or release secret is configured.
- **Rotate** by updating `secret/infra/github-mirror` (or the file) and re-running `bootstrap.ps1`. The stack
  refreshes the Secret and restarts Atlantis (environment variables are read at start), and the mirrors are
  recreated, because Gitea cannot edit one.
- Gitea keeps the token in its own database, so it is as exposed as Gitea's data volume. Use a fine-grained token
  limited to the mirrored repositories with *Contents: read and write*. If a mirror shows
  `Write access to repository not granted` in Gitea, the token lacks that permission on that repository.

## Re-running and failure recovery

- Every stack is idempotent. Running `bootstrap.ps1` again continues from the state already recorded: existing
  passwords and tokens are kept and a repository push with nothing new is skipped.
- If it stops half-way, fix the cause and run it again. To work on one stack, run it directly, for example
  `tofu -chdir=..\stacks\30-gitea-extra plan`. Bootstrap stacks default to context `k3d-xenomit`.
- Once `main` of a repository is protected, `bootstrap.ps1` cannot push to it. If your checkout is ahead of
  Gitea, the script pushes the difference to the branch `bootstrap-sync` and prints a warning. Open a pull
  request from that branch. A merged pull request comes back as a fast-forward on the next run.
- A cluster built before this layout (stacks, `ops/stacks.txt`) cannot be updated in place: its local state
  still lists resources that moved to other stacks. The script detects it and asks for `-Reset`.
- A failed `tofu apply` after a manual cluster change can leave objects that OpenTofu does not know about
  ("already exists"). The quickest fix on a local cluster is `-Reset`.
- The state files contain secrets. Do not copy them off the machine.

## Day 2: changing the platform

Edit the local repository, push a branch to Gitea, and open a pull request against `main`. Atlantis comments with
a plan. Reply `atlantis apply`. Atlantis applies that plan and merges. Direct pushes to `main` on the three
platform repositories are rejected. Image digest updates belong in `services/gitops` and go through the same
pull request.

Changes under `bootstrap/`, `stacks/` and `ops/` are not Atlantis projects. They reach Gitea through a pull
request like everything else, but they are applied by re-running `bootstrap.ps1`.

## Local run after a reboot

Start Docker Desktop, then unseal Vault. The k3d cluster and its volumes come back with Docker; Vault does not
unseal itself. The load balancer publishes the UIs on loopback again.

```powershell
cd <checkouts>\xenomit-platform\ops
.\vault\vault-init.ps1
kubectl config use-context k3d-xenomit
kubectl get pods -A
```

From the host, clone or push with `http://127.0.0.1:3000/xenomit/<repo>.git`. Inside the cluster, Argo CD and
Atlantis use `http://gitea.git.svc.cluster.local:3000`.

The panel and orchestrator stay unready until their images exist in `xenomit-registry:5000` and pass the Cosign
policy. A fresh registry has nothing to pull. OpenObserve, the collector, Postgres, Gitea, Argo CD, and Atlantis do
not depend on that registry.
