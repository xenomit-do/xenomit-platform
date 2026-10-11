# Atlantis operations and self-upgrades

Open a same-repository PR. Autoplan posts results; fork infrastructure PRs are rejected. Only the
platform-maintainers team can manually plan/apply/import/unlock. Apply requires mergeability and an
undiverged plan; base changes require replanning. Infrastructure PRs require Atlantis plan/apply
checks, and the server understands the apply-check dependency. Successful apply automerges.

Treat changes to infra/00-identity and infra/20-controllers, mounted credentials, and Atlantis itself
as host maintenance: a process cannot reliably restart itself and finish posting/merging its PR.
Pause Atlantis, obtain the reviewed PR revision in a clean worktree, initialize the SAME Kubernetes
backend key using scripts/lib.sh, plan, review, and apply that project from the host. Re-run verify,
then restore replicas, replan remaining projects, and merge the PR through the documented owner
maintenance procedure. Do not bootstrap unrelated latest-main configuration over a reviewed PR apply.
For protected statuses blocked by a self-restart, post the verified result as an owner or use a
temporarily reviewed protection exception and immediately restore it. Record that intervention in PR.

Never unlock an active apply. Verify the process stopped before clearing a stale Atlantis lock;
Kubernetes state locks remain a separate protection. Merge or revert applied PRs before teardown.

Webhook downtime: start laptop/Docker/cloudflared, inspect GitHub Settings > Webhooks > Recent
deliveries, select failed relevant deliveries and Redeliver. Review current PR revisions and replan
before applying; GitHub does not guarantee replay of every event while a laptop is offline.

The required `atlantis/apply` status is handled using `ATLANTIS_GH_ALLOW_MERGEABLE_BYPASS_APPLY=true`, as documented in https://www.runatlantis.io/docs/command-requirements. This resolves the circular apply check while preserving other required CI and mergeability gates.
