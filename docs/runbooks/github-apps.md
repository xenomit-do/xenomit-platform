# GitHub access

Create organization-owned GitHub Apps under xenomit-do Settings > Developer settings > GitHub Apps.
These account registrations and initial credentials are the one-time trust root. Install apps on
the organization and save private keys outside Git. Record app IDs and installation IDs in config.

Atlantis app: repository Administration read, Actions read, Checks/Commit statuses/Contents/Issues/
Pull requests read-write; organization Members read. Install only on catalog Atlantis repositories.
Disable the App's own webhook delivery: OpenTofu manages repository webhooks, avoiding duplicate
delivery. Atlantis mounts its key and generates installation tokens itself.

ARC app: organization Self-hosted runners read-write and repository Metadata read. It registers
organization scale sets; runner groups separately restrict repository access. Save a separate key.
Argo reads public repositories anonymously and does not require an App key.

For OpenTofu/bootstrap supply an organization-owner administration token scoped to repository
administration, contents, workflows, pull requests, Actions variables/secrets, runner groups,
members/teams and organization settings. Restrict it to xenomit-do. This privileged credential
is mounted only into Atlantis and the default-branch platform-admin reconciliation environment.
Never place it in ordinary CI jobs or the public catalog. Prefer a dedicated administration App
installation token supplied by your credential tooling where its permissions support these APIs.

Create repositories only through repository-onboarding.md. Members' repository creation is disabled
by OpenTofu; organization owners can still bypass that account-level policy and are audited.
