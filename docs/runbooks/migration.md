# Migration and public publication

Run scripts/inventory.sh before changing remotes. Retain .xenomit/inventory.json and an offline copy
of each checkout including .git, uncommitted files and tags. Inventory never logs credential-bearing
remote URLs. GitHub commit history survives; deleted Gitea PR history without backups is unrecoverable.

For each repo fetch GitHub and inspect branches/tags. Push missing local commits to migration branches
and open PRs. Never use push --mirror or force push: they can remove GitHub refs. Move old gitea remotes
to a legacy name and add origin pointing to github.com/xenomit-do/<repo>.git only after reviewing them.
Preserve historical platform repositories on GitHub before setting archived=true in the catalog.

Before publishing private code, run scripts/audit-publication.sh <checkout> <private-report-dir> using
gitleaks 8.24.3 against full Git history. Fetch all remote branches/tags first. Inspect tracked files and
history for personal data, account/session data, commercial assets and proprietary content beyond
the scanner. Remove unsuitable material; rotate exposed credentials. History rewriting needs a
separately reviewed migration, never an automatic bootstrap force push.

After cleanup has reached GitHub, record a private publication-audits.json entry:

```json
{"repo-name":{"github_head":"FULL_CURRENT_DEFAULT_BRANCH_SHA","secret_scan_passed":true,"reviewed_private_data":true}}
```

The auditor attests the full history review; booleans are not an automated proof. Bootstrap and the
OpenTofu precondition reject private visibility changes without a current attestation. Refresh it
after further commits. Public visibility is an actual publication and should follow this review.

Initially reconcile the catalog with all organization repos and their real default branches before
applying. No live public conversions or GitHub pushes are part of local implementation validation.

If inventory reports source_without_git_history, preserve that directory separately before cloning. Recover .git from an offline checkout or GitHub when possible. Compare surviving source against a fresh GitHub clone and import the difference through a migration branch/PR; do not replace the remote history or silently treat a source-only directory as a valid checkout. The local xenomit-orchestrator directory currently has this condition and also lacks its declared e2e member.
