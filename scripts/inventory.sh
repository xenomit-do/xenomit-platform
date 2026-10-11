#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workspace=${1:-$(dirname "$ROOT")}
mkdir -p "$workspace/.xenomit"; chmod 700 "$workspace/.xenomit"
python3 "$ROOT/scripts/platform.py" inventory "$ROOT/repositories.json" "$workspace" "$workspace/.xenomit/inventory.json"
printf 'Inventory saved privately to %s/.xenomit/inventory.json\n' "$workspace"
