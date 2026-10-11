#!/usr/bin/env bash
# detect-pr-flow.sh — the game-update pipeline of docs/07 §7.1 in one script.
#
# Subcommands (also the container args in cronjob-detect.yaml / job-apply.yaml):
#
#   detect   CronJob step (every 10 min): fetch main.swf, run
#            `xenomit-packet-updater detect`. Exit 0 → done. Exit 10/30 →
#            render the apply-Job template and kubectl-create it.
#   apply    Job step: fresh clone → `apply --ffdec` → upgrade.json →
#            branch auto/packet-<hash> → push + PR (EXECUTE=1 only).
#   check    Offline pre-flight: `apply --check-only` on a fetched/copied
#            SWF. Same exit contract, zero writes — safe anywhere.
#
# DRY-RUN BY DEFAULT. The only steps that contact the outside world for real
# (git push, PR creation) run solely when EXECUTE=1 is passed; everything
# else is printed. The CronJob ships with EXECUTE=0 until you flip it.
#
# Required env per subcommand:
#   detect : SWF_URL (direct) or FLASHVARS_URL (parsed for a main.swf?__cv= link)
#   apply  : REPO_URL (ssh), GIT_SSH_COMMAND (deploy key), SWF_URL,
#            baseline+targets live inside the checkout
#   all    : WORK_DIR (scratch, default /tmp/xpu), JOB_TEMPLATE,
#            APPLY_IMAGE, APPLY_NAMESPACE (detect only)
set -euo pipefail

WORK_DIR="${WORK_DIR:-/tmp/xpu}"
JOB_TEMPLATE="${JOB_TEMPLATE:-/etc/xenomit/job-apply.yaml}"
APPLY_IMAGE="${APPLY_IMAGE:-xenomit-packet-updater:latest}"
APPLY_NAMESPACE="${APPLY_NAMESPACE:-ci}"
EXECUTE="${EXECUTE:-0}"
UPDATER="${XENOMIT_PACKET_UPDATER:-xenomit-packet-updater}"
FFDEC="${FFDEC:-ffdec}"
GIT_BRANCH="${GIT_BRANCH:-main}"
# baseline/bindings are NOT installed by pip (repo-root data files) — point at
# the source tree baked into the image (detect) or into the checkout (apply).
# The tool resolves sibling repos from the *package location*, never CWD, so
# every path is passed explicitly.
PKG_DIR="${PKG_DIR:-/opt/xenomit-packet-updater}"

log()  { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------- swf fetch
# Fetching stays outside the tool (docs/07 §7.1): resolve a URL then curl.
fetch_swf() {
  local dest="$1"
  if [ -n "${SWF_URL:-}" ]; then
    curl -fsSL --retry 3 --connect-timeout 15 "$SWF_URL" -o "$dest"
  elif [ -n "${FLASHVARS_URL:-}" ]; then
    # backpage flashvars → CDN main.swf?__cv=… (first quoted .swf URL wins)
    local url
    url=$(curl -fsSL --retry 3 "$FLASHVARS_URL" \
          | grep -oE 'https?://[^"'"'"' ]+main\.swf[^"'"'"' ]*' | head -n1) \
      || die "no main.swf URL found in flashvars"
    curl -fsSL --retry 3 "$url" -o "$dest"
  else
    die "set SWF_URL or FLASHVARS_URL"
  fi
  [ -s "$dest" ] || die "empty download: $dest"
}

# ------------------------------------------------------------- spawn job
spawn_apply_job() {
  local hash12="$1"
  local ts name
  ts=$(date -u +%Y%m%d%H%M%S)
  name="packet-apply-${hash12}-${ts}"
  log "detect reported a change (swf ${hash12}); creating Job ${name}"
  if [ ! -f "$JOB_TEMPLATE" ]; then
    die "job template not found: $JOB_TEMPLATE"
  fi
  # Token replacement, no envsubst dependency.
  sed -e "s|__JOB_NAME__|${name}|g" \
      -e "s|__IMAGE__|${APPLY_IMAGE}|g" \
      -e "s|__NAMESPACE__|${APPLY_NAMESPACE}|g" \
      -e "s|__SWF_URL__|${SWF_URL:-}|g" \
      -e "s|__FLASHVARS_URL__|${FLASHVARS_URL:-}|g" \
      "$JOB_TEMPLATE" > "${WORK_DIR}/job-rendered.yaml"
  log "rendered ${WORK_DIR}/job-rendered.yaml"
  if [ "$EXECUTE" = "1" ]; then
    kubectl apply -f "${WORK_DIR}/job-rendered.yaml"
  else
    log "dry-run: would run 'kubectl apply -f ${WORK_DIR}/job-rendered.yaml'"
    cat "${WORK_DIR}/job-rendered.yaml" >&2 || true
  fi
}

# ------------------------------------------------------------------ detect
cmd_detect() {
  mkdir -p "$WORK_DIR"
  fetch_swf "${WORK_DIR}/main.swf"
  set +e
  "$UPDATER" detect --swf "${WORK_DIR}/main.swf" \
      --baseline "${PKG_DIR}/baseline.json" \
      --bindings "${PKG_DIR}/bindings.toml" \
      --out "${WORK_DIR}/detect.json"
  rc=$?
  set -e
  log "detect exit=$rc payload=${WORK_DIR}/detect.json"
  case "$rc" in
    0)      log "baseline current — nothing to do"; exit 0 ;;
    10|30)
      swfhash=$(python3 -c "import json;print(json.load(open('${WORK_DIR}/detect.json'))['swf_sha256'][:12])")
      spawn_apply_job "$swfhash"
      ;;
    *)      die "detect tool failure (exit $rc)" ;;
  esac
}

# ------------------------------------------------------------------- apply
cmd_apply() {
  : "${REPO_URL:?set REPO_URL (ssh clone URL)}"
  mkdir -p "$WORK_DIR"
  local co="${WORK_DIR}/checkout"
  [ -d "$co/.git" ] || git clone --depth 1 --branch "$GIT_BRANCH" "$REPO_URL" "$co"

  fetch_swf "${WORK_DIR}/main.swf"

  # Paths point into the checkout — its baseline/bindings may be ahead of the
  # image's baked copies if a previous update already merged.
  set +e
  "$UPDATER" apply --swf "${WORK_DIR}/main.swf" --ffdec "$FFDEC" \
      --baseline "${co}/xenomit-packet-updater/baseline.json" \
      --bindings "${co}/xenomit-packet-updater/bindings.toml" \
      --packet-client "${co}/xenomit-packet-client" \
      --raylib "${co}/xenomit-raylib-client" \
      --server "${co}/xenomit-server" \
      --out "${WORK_DIR}/upgrade.json" --update-baseline
  rc=$?
  set -e
  log "apply exit=$rc manifest=${WORK_DIR}/upgrade.json"

  [ "$rc" -eq 10 ] || [ "$rc" -eq 30 ] || {
    [ "$rc" -eq 0 ] && { log "no change after decompile — done"; exit 0; }
    die "apply tool failure (exit $rc)"
  }

  local swfhash cls branch
  swfhash=$(python3 -c "import json;print(json.load(open('${WORK_DIR}/upgrade.json'))['next']['swf_sha256'][:12])")
  cls=$(python3 -c "import json;print(json.load(open('${WORK_DIR}/upgrade.json'))['exit_class'])")
  branch="auto/packet-${swfhash}"
  log "exit_class=${cls} branch=${branch}"

  cd "$co"
  git checkout -b "$branch"
  git add -A
  git -c user.name="xenomit-packet-updater" \
      -c user.email="packet-updater@xenomit.local" \
      commit -m "packet: update to swf ${swfhash}

$(cat "${WORK_DIR}/upgrade.json")"

  if [ "$EXECUTE" = "1" ]; then
    # Deploy key / GitHub App token with auto/* + PR scope only — no push
    # to main (docs/07 §7.1, docs/09 §9.2).
    git push -u origin "$branch"
    if command -v gh >/dev/null 2>&1; then
      gh pr create --fill \
        --title "packet: auto update ${swfhash} (${cls})" \
        --body-file "${WORK_DIR}/upgrade.json" \
        --base "$GIT_BRANCH"
    else
      log "gh not installed; open a PR for ${branch} with upgrade.json as the body"
    fi
  else
    log "dry-run: would 'git push -u origin ${branch}' and open a PR with upgrade.json as the body"
  fi
  # exit_class is the contract CI routes on: ids → auto-merge path,
  # review → human required (docs/07 §7.1). Preserve the tool's code.
  exit "$rc"
}

# ------------------------------------------------------------------- check
cmd_check() {
  # Run against a checkout when CHECKOUT_DIR is set (Job shape), otherwise
  # against the image-baked tree with explicit sibling overrides.
  local co="${CHECKOUT_DIR:-$PKG_DIR/..}"
  mkdir -p "$WORK_DIR"
  local swf="${WORK_DIR}/main.swf"
  if [ -n "${SWF_PATH:-}" ]; then cp "$SWF_PATH" "$swf"; else fetch_swf "$swf"; fi
  set +e
  "$UPDATER" apply --swf "$swf" --check-only \
      --ffdec "$FFDEC" \
      --baseline "${co}/xenomit-packet-updater/baseline.json" \
      --bindings "${co}/xenomit-packet-updater/bindings.toml" \
      --packet-client "${co}/xenomit-packet-client" \
      --raylib "${co}/xenomit-raylib-client" \
      --server "${co}/xenomit-server" \
      ${MODULES_JSON:+--modules-json "$MODULES_JSON"} \
      --out "${WORK_DIR}/upgrade.json"
  rc=$?
  set -e
  log "check-only exit=$rc manifest=${WORK_DIR}/upgrade.json"
  exit "$rc"
}

case "${1:-}" in
  detect) cmd_detect ;;
  apply)  cmd_apply ;;
  check)  cmd_check ;;
  *) die "usage: detect-pr-flow.sh detect|apply|check" ;;
esac
