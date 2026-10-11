# Ownership and recovery contract

OpenTofu's five projects own identities/secrets, external GitHub/Cloudflare objects, controllers,
shared services, and Vault JWT authorization. Kubernetes Secrets and Leases in atlantis-state provide storage and locking.
Bootstrap and Atlantis use the same state suffixes. Pending plans/locks are not recovery data.

Git stores desired configuration, not OpenTofu resource identities. New clusters use fresh state;
the external recovery importer discovers and imports repositories, branch policies, environments,
teams, memberships, runner groups, webhooks, tunnels and DNS before applying. Ambiguity blocks apply.
Existing cluster state is reused. Loss of identity state while live credentials survive blocks
bootstrap; restore that state instead of resetting passwords.

OpenTofu owns Argo projects and Applications. Argo owns only manifests allowed by each project:
runner resources in ARC namespaces, desired fleet CRs in xenomit-bots, application services in
xenomit-system. The operator owns status/finalizers and workload children. Fleet CRs carry
xenomit.io/spec-owner=argocd. Deployed API GitOps mode rejects spec-changing endpoints on both API
surfaces, while allowing reads and credential submission. Runtime credentials never enter Git.

Only one workspace controls a named environment. A GitHub variable records the owner ID, and a local
flock excludes simultaneous host bootstrap. Kubernetes state locking also serializes Atlantis and
host applies. The organization-wide XENOMIT_ACTIVE_ENVIRONMENT claim forbids another workspace from controlling any environment until teardown or explicit recovery transfers ownership.

Databases, bot credentials, generated passwords, ephemeral runner disks and Atlantis plans can be lost.
Reproduction means current merged GitHub configuration and recoverable Git history, not bitwise
runtime data. Unmerged Atlantis applies must be merged or reverted before transferring machines.

Local Vault runs in explicitly disposable development mode, with a generated admin token and
JWT policies configured by the fifth infrastructure project. It is private to the cluster; runner
egress excludes it. Restarting Vault loses bot credentials and requires reapplying its configuration.
Use persistent initialized Vault for a production environment; this profile targets disposable k3d.
