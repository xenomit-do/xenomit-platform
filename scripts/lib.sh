#!/usr/bin/env bash
umask 077
log() { printf '%s\n' "$*" >&2; }
die() { log "$*"; exit 1; }
preflight() {
  [[ $(uname -s) == Linux ]] || die 'Use Linux or WSL, with repositories on its native filesystem.'
  local tool
  for tool in docker k3d kubectl git tofu python3 jq curl openssl flock; do
    command -v "$tool" >/dev/null || die "Missing dependency: $tool. See docs/runbooks/bootstrap.md"
  done
  [[ -f $1 ]] || die "Missing configuration: $1. Copy config.example.json outside Git."
  docker info >/dev/null || die 'Docker is not reachable.'
  [[ $(tofu version -json | jq -r .terraform_version) == 1.12.6 ]] || die 'OpenTofu 1.12.6 is required.'
  [[ $(k3d version | head -n1) == *v5.8.3* ]] || die 'k3d v5.8.3 is required.'
}
init_stack() {
  : "${TF_VAR_kube_context:?Missing Kubernetes context}"
  tofu -chdir="$ROOT/$1" init -reconfigure -input=false \
    -backend-config="secret_suffix=xenomit-$2" \
    -backend-config='in_cluster_config=false' \
    -backend-config="config_path=$KUBECONFIG" \
    -backend-config="config_context=$TF_VAR_kube_context"
}
