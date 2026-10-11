#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
workspace="$(dirname "$ROOT")"
if (($#)); then [[ $1 == --workspace && $# == 2 ]] || die 'Usage: verify.sh [--workspace PATH]'; workspace=$2; fi
state="$workspace/.xenomit"
[[ -f $state/kubeconfig && -f $state/runtime.auto.tfvars.json ]] || die 'Bootstrap metadata missing.'
export KUBECONFIG="$state/kubeconfig"
kubectl get --raw=/readyz >/dev/null
for deployment in atlantis cloudflared; do kubectl -n ci rollout status "deployment/$deployment" --timeout=180s; done
deadline=$((SECONDS + 600))
until python3 "$ROOT/scripts/platform.py" verify "$ROOT/repositories.json" "$state/runtime.auto.tfvars.json"; do
  ((SECONDS < deadline)) || die 'Verification failed; inspect Argo conditions and docs/runbooks/recovery.md.'
  sleep 10
done
