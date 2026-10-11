#!/bin/sh
# Runs INSIDE the gitea pod (kubectl exec deploy/gitea -- sh /bootstrap/gitea-admin.sh).
# Creates the `gitops` site admin, or resets its password if it already exists.
# This is the one step the Gitea API cannot do: the first admin has to come from
# the CLI. Everything after it (org, users, tokens, repos) uses the API.
set -eu
gitea() { su-exec git env HOME=/data/git gitea --config /data/gitea/conf/app.ini "$@"; }

if gitea admin user list --admin | grep -qw gitops; then
  gitea admin user change-password --username gitops --password "$GITOPS_PASSWORD" --must-change-password=false
else
  gitea admin user create --admin --username gitops --email gitops@xenomit.local \
    --password "$GITOPS_PASSWORD" --must-change-password=false
fi
