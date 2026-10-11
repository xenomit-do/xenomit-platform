#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
workspace="$(dirname "$ROOT")"; external=false
while (($#)); do case "$1" in
  --workspace) workspace=${2:?}; shift 2 ;;
  --external) external=true; shift ;;
  *) die "Unknown argument: $1" ;;
esac; done
state="$workspace/.xenomit"
[[ -f $state/runtime.auto.tfvars.json && -f $state/kubeconfig ]] || die 'Missing environment metadata; use the recovery runbook.'
export KUBECONFIG="$state/kubeconfig"
export TF_VAR_kube_config_path="$KUBECONFIG"
TF_VAR_kube_context="k3d-$(jq -r '.config.cluster_name' "$state/runtime.auto.tfvars.json")"
export TF_VAR_kube_context
exec 9>"$state/bootstrap.lock"; flock -n 9 || die 'Bootstrap is running.'
if $external; then
  die 'External deletion is blocked by prevent_destroy. Follow docs/runbooks/teardown.md and review a separate deletion plan; GitHub history is never part of cluster teardown.'
fi
kubectl -n ci scale deployment/atlantis deployment/cloudflared --replicas=0
kubectl -n ci wait --for=delete pod -l app=atlantis --timeout=120s
cluster=$(jq -r '.config.cluster_name' "$state/runtime.auto.tfvars.json")
k3d cluster delete "$cluster"
python3 "$ROOT/scripts/release-owner.py" "$state/runtime.auto.tfvars.json" "$state/owner-id"
log 'Cluster deleted. GitHub, DNS, tunnel, workspace checkouts and inventory remain. Rebootstrap generates new cluster state.'
