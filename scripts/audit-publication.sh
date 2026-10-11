#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
repo=${1:?Usage: audit-publication.sh REPOSITORY_PATH REPORT_DIRECTORY}
reports=${2:?Report directory required}
command -v gitleaks >/dev/null || { echo 'Install pinned gitleaks 8.24.3 first' >&2; exit 1; }
[[ $(gitleaks version) == 8.24.3 ]] || { echo 'Expected gitleaks 8.24.3' >&2; exit 1; }
mkdir -p "$reports"; chmod 700 "$reports"
gitleaks git "$repo" --log-opts=--all --redact --report-format json --report-path "$reports/secrets.json"
git -C "$repo" ls-files >"$reports/tracked-files.txt"
git -C "$repo" log --all --format='%H %s' >"$reports/history.txt"
echo 'Secret scan passed. Review tracked files and full history for personal/private/proprietary content; rotate any previously exposed credentials. See migration.md for publication attestation.'
