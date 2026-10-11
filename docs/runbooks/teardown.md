# Teardown

Confirm merged GitHub state contains all desired infrastructure and deployment changes, and publish
surviving branches/tags before teardown. Run bash destroy.sh --workspace <workspace>. It stops Atlantis
and the connector, deletes only the named k3d cluster, then releases remote ownership. Local checkouts,
external GitHub resources, Cloudflare tunnel/DNS and private inventory remain.

Destroy never recursively deletes the workspace or runs tofu destroy against repositories. --external
fails with instructions: external deletion needs a separate reviewed plan explicitly removing
prevent_destroy for the exact tunnel/DNS resources. Never remove GitHub repository protection merely
to allow a blanket destroy. GitHub histories are not ephemeral cluster data.

If teardown stops after deleting k3d, release the matching ownership variable using the recovery
procedure. Restart with bootstrap, which refreshes .xenomit/kubeconfig and uses fresh cluster state.
