#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
workspace="$(dirname "$ROOT")"
config="${XENOMIT_CONFIG:-$HOME/.config/xenomit/config.json}"
while (($#)); do
  case "$1" in
    --workspace) workspace=${2:?missing workspace}; shift 2 ;;
    --config) config=${2:?missing config}; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
preflight "$config"
[[ $workspace != /mnt/* ]] || die 'Choose a Linux-native workspace, not a Windows-mounted path.'
mkdir -p "$workspace"
workspace=$(cd "$workspace" && pwd)
state="$workspace/.xenomit"
mkdir -p "$state"; chmod 700 "$state"
exec 9>"$state/bootstrap.lock"
flock -n 9 || die 'Another bootstrap is running in this workspace.'
python3 "$ROOT/scripts/platform.py" prepare "$config" "$state/runtime.auto.tfvars.json"
export TF_VAR_kube_config_path="$state/kubeconfig"
TF_VAR_kube_context="k3d-$(jq -r '.config.cluster_name' "$state/runtime.auto.tfvars.json")"
export TF_VAR_kube_context
export KUBECONFIG="$TF_VAR_kube_config_path"
python3 "$ROOT/scripts/platform.py" workspace "$ROOT/repositories.json" "$workspace" "$state/revisions.json"
python3 "$ROOT/scripts/platform.py" lease "$state/runtime.auto.tfvars.json" "$state/owner-id"
cluster=$(jq -r '.config.cluster_name' "$state/runtime.auto.tfvars.json")
if ! k3d cluster list -o json | jq -e --arg name "$cluster" '.[] | select(.name == $name)' >/dev/null; then
  jq --arg name "$cluster" '.metadata.name = $name' "$ROOT/ops/k3d/cluster-unix.json" >"$state/k3d.json"
  k3d cluster create --config "$state/k3d.json"
fi
k3d kubeconfig get "$cluster" >"$KUBECONFIG"
chmod 600 "$KUBECONFIG"
issuer=$(kubectl get --raw=/.well-known/openid-configuration | jq -r .issuer)
python3 - "$state/runtime.auto.tfvars.json" "$issuer" <<'PY'
import json,sys
p=sys.argv[1]
c=json.load(open(p)); c['config']['jwt_issuer']=sys.argv[2]
json.dump(c,open(p,'w'),indent=2)
PY
kubectl --context "$TF_VAR_kube_context" wait node --all --for=condition=Ready --timeout=180s
kubectl create namespace atlantis-state --dry-run=client -o yaml | kubectl apply -f -
while read -r project path; do
  log "Applying $project"
  init_stack "$path" "$project"
  if [[ $project == identity ]]; then
    python3 "$ROOT/scripts/platform.py" import-identity "$ROOT/$path" "$state/runtime.auto.tfvars.json"
  elif [[ $project == external ]]; then
    python3 "$ROOT/scripts/platform.py" import-external "$ROOT/$path" "$state/runtime.auto.tfvars.json" "$ROOT/repositories.json"
  fi
  if [[ $project == vault ]]; then
    kubectl -n xenomit-system port-forward svc/vault 18200:8200 >"$state/vault-forward.log" 2>&1 &
    vault_pid=$!
    trap 'kill "${vault_pid:-}" 2>/dev/null || true' EXIT
    for _attempt in {1..30}; do curl -fsS http://127.0.0.1:18200/v1/sys/health >/dev/null && break; sleep 1; done
    curl -fsS http://127.0.0.1:18200/v1/sys/health >/dev/null || die "Vault did not become ready; inspect $state/vault-forward.log"
    curl -fsS http://127.0.0.1:18200/v1/sys/health >/dev/null || die "Vault did not become ready; inspect $state/vault-forward.log"
    export TF_VAR_vault_address=http://127.0.0.1:18200
  fi
  tofu -chdir="$ROOT/$path" apply -lock-timeout=5m -var-file="$state/runtime.auto.tfvars.json" -auto-approve
  if [[ $project == vault ]]; then
    kill "$vault_pid"; unset TF_VAR_vault_address; trap - EXIT
  fi
  if [[ $project == controllers ]]; then
    kubectl -n ci rollout status deployment/atlantis --timeout=600s
    kubectl -n ci rollout status deployment/cloudflared --timeout=180s
  fi
done <"$ROOT/infra/stacks.txt"
python3 "$ROOT/scripts/platform.py" workspace "$ROOT/repositories.json" "$workspace" "$state/revisions.json"
python3 "$ROOT/scripts/platform.py" onboard "$ROOT/repositories.json" "$state/runtime.auto.tfvars.json" "$ROOT/ci/templates/source-check.yml"
bash "$ROOT/verify.sh" --workspace "$workspace"
log 'Bootstrap complete. Argo UI: http://127.0.0.1:8080. Atlantis UI: kubectl -n ci port-forward svc/atlantis 4141:4141'
