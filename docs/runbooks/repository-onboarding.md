# Repository creation and branch protection

1. Add an entry to repositories.json through a platform PR: name, actual default branch, workspace,
   CI profile, required checks, Atlantis flag, archive flag. Use source/source-check / source-check for code repos.
2. For existing GitHub repositories the importer adopts settings without overwriting Git history.
   Complete publication review for any private repository. New repos initialize a public README.
3. Review Atlantis's external plan, then an allowlisted maintainer comments atlantis apply. Atlantis
   applies and merges; subsequent bootstrap clones the repo. Infra changes remain in GitHub main.
4. Run the onboarding helper/bootstrap to open a source-check workflow PR. Merge after its runner
   check passes. Extend CI with language/project tests and register their stable check names.
5. Verify public visibility, PR/admin protection, required checks, resolved conversations, no default
   branch deletion/force push, deletion after merge, fork-ci approval, and correct runner-group access.

Protection defaults apply via one OpenTofu for_each module to every catalog repo. Zero human approvals
supports solo work; CI remains required. Owners can create repositories outside this process, but
hourly catalog reconciliation proposes additions and verify.sh rejects missing policy coverage.
The scheduled job runs on xenomit-platform, so it needs the laptop running; run it manually after downtime.

Change required checks through a platform PR only after the matching workflow exists. Never rename a
required job without updating policy. Default branches remain main unless catalog records an existing
different branch. Do not force-rename upstream fork branches (for example Ruffle) during migration.

Inventory inherited .github/workflows before onboarding. Migrate jobs into the protected reusable workflows and managed pools, or disable unsuitable upstream workflows. Verification rejects remaining GitHub-hosted runner requests; all fork jobs must pass the trusted approval gate.
