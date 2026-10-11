# Partial bootstrap and machine migration

Fix the reported prerequisite/provider error and rerun bootstrap. Existing healthy cluster state is
reused. Do not delete state to silence an already-exists error. The importer only handles inventoried
external types; duplicate identities fail rather than guessing. Restore lost identity state if Secrets
survive. Lost controller/service state on a live cluster needs reviewed imports or a disposable rebuild.

Verification checks repository coverage/policies, public visibility, Argo health/sync, online runner
pools, public-root isolation and unsigned webhook rejection. Missing images, credentials and Argo errors
remain failures. Use kubectl describe application -n argocd and controller logs for diagnostics.

Before moving machines, merge or revert all applied PRs, complete GitHub commit/tag publication, run
verify, then destroy the old cluster. This releases its GitHub environment ownership variable. Clone
platform on the new machine, supply external credentials, and bootstrap the same environment ID.
Persistent external resources are imported; cluster passwords/databases are recreated.

If the old laptop is lost, first revoke its Atlantis/ARC keys and tunnel access, stop its execution,
then delete XENOMIT_ACTIVE_ENVIRONMENT from platform Actions variables as the explicit transfer step.
Record the transfer in a platform PR/issue. Never clear it while the old environment can still apply.
Run the rebuild drill: merge an Atlantis change, delete cluster, bootstrap on another machine, verify
the exact committed change and external identity preservation. Acceptance requires this live drill.
