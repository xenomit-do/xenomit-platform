# Shared branch protection

Every catalog repository gets default-branch protection from infra/10-external: PR required, zero mandatory human approvals, strict required checks, resolved conversations, administrators included, force pushes and branch deletion refused. delete_branch_on_merge=true applies to every repository and deletes eligible PR head branches after merging. Protected branches remain protected, and GitHub cannot delete a contributor's fork branch on their behalf.

Change policy and stable check names in repositories.json and OpenTofu through a platform PR. Apply with Atlantis; verify.sh audits live coverage. Required reusable job contexts are source-check / source-check and platform-check / platform-check. Infrastructure participation adds atlantis/plan and atlantis/apply. Merge a test PR and confirm checks plus head-branch deletion during the first live acceptance drill.

For a renamed default branch, create and push its commits before updating the catalog. Import an existing protection with scripts/platform.py import-external; never replace existing Git history. Repository onboarding creates workflow PRs automatically, and the scheduled reconciliation repeats it after newly registered repositories appear.

Restrict repository creation through the catalog process. Owner-created unregistered repositories fail verification and receive a proposed catalog addition; no discovered private repository becomes public without the publication review.
