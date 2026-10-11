#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workspace=$(mktemp -d)
trap 'docker logout ghcr.io >/dev/null 2>&1 || true; rm -rf -- "$workspace"' EXIT
python3 "$ROOT/scripts/platform.py" workspace "$ROOT/repositories.json" "$workspace" "$workspace/revisions.json"
cp "$workspace/revisions.json" "$workspace/source-revisions.json"
python3 - "$workspace" "$ROOT" <<'PY'
import json,os,pathlib,shutil,sys
target=pathlib.Path(sys.argv[1])/'xenomit-platform'
# Use the workflow's checked-out platform revision, even if its default branch moved.
shutil.rmtree(target)
shutil.copytree(sys.argv[2],target,dirs_exist_ok=True,ignore=shutil.ignore_patterns('.git','.terraform','.xenomit'))
report=pathlib.Path(sys.argv[1])/'source-revisions.json'
revisions=json.loads(report.read_text())
revisions['repositories']['xenomit-platform']=os.environ['GITHUB_SHA']
report.write_text(json.dumps(revisions,indent=2)+'\n')
print(report.read_text())
PY
command -v docker >/dev/null || { echo 'Docker CLI is missing in the build runner.' >&2; exit 1; }
docker info >/dev/null
printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
curl -fsSL https://github.com/sigstore/cosign/releases/download/v2.4.3/cosign-linux-amd64 -o "$workspace/cosign"
chmod 700 "$workspace/cosign"
docker buildx create --use --name "xenomit-${GITHUB_RUN_ID}" --driver docker-container
for image in orchestrator web-panel botd; do
  case "$image" in
    orchestrator) dockerfile=xenomit-orchestrator/ci/docker/Dockerfile.orchestrator ;;
    web-panel) dockerfile=xenomit-platform/services/docker/Dockerfile.web-panel ;;
    botd) dockerfile=xenomit-botd/Dockerfile ;;
  esac
  [[ -f $workspace/$dockerfile ]] || { echo "Missing committed Dockerfile: $dockerfile" >&2; exit 1; }
  docker buildx build --push --provenance=true --sbom=true \
    --tag "ghcr.io/xenomit-do/xenomit-$image:$GITHUB_SHA" \
    --label "org.opencontainers.image.revision=$GITHUB_SHA" \
    --label "org.opencontainers.image.source=https://github.com/xenomit-do/xenomit-platform" \
    --metadata-file "$workspace/$image.json" -f "$workspace/$dockerfile" "$workspace"
  digest=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["containerimage.digest"])' "$workspace/$image.json")
  "$workspace/cosign" sign --yes "ghcr.io/xenomit-do/xenomit-$image@$digest"
done
python3 - "$workspace" "$GITHUB_OUTPUT" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
digests={i:json.loads((root/(i+'.json')).read_text())['containerimage.digest'] for i in ('orchestrator','web-panel','botd')}
with open(sys.argv[2],'a') as output: output.write('digests='+json.dumps(digests,separators=(',',':'))+'\n')
PY
