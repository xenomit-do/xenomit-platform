#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
for script in "$ROOT"/*.sh "$ROOT"/scripts/*.sh; do bash -n "$script"; done
if command -v shellcheck >/dev/null; then shellcheck -P "$ROOT" -x "$ROOT"/*.sh "$ROOT"/scripts/*.sh; fi
python3 -m unittest discover -s "$ROOT/tests" -v
tofu fmt -check -recursive "$ROOT/infra"
for stack in "$ROOT"/infra/??-*; do
  tofu -chdir="$stack" init -backend=false -input=false
  tofu -chdir="$stack" validate
done

tofu -chdir="$ROOT/infra/30-services" test
