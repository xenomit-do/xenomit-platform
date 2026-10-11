# Gitea configuration for repositories that Atlantis must not reach: they are not in its
# repository allowlist, not in the platform-infra team, and atlantis is not an
# organization owner. The xenomit-platform-gitea stack covers the platform repositories.

locals {
  github_enabled = nonsensitive(var.github_mirror_token != null)
}

data "kubernetes_secret" "gitops" {
  metadata {
    name      = "gitops-git"
    namespace = "git"
  }
}

# Created empty; ops/bootstrap.ps1 pushes the checkouts listed in seed_repositories right
# after this stack.
resource "gitea_repository" "extra" {
  for_each       = var.extra_repositories
  username       = var.gitea_org
  name           = each.key
  description    = each.value.description
  private        = true
  default_branch = "main"
  auto_init      = false

  lifecycle {
    ignore_changes = all
  }
}

# Changes reach main through pull requests. Only the gitops admin may push to it directly,
# which is how the bootstrap seeds a repository on a new machine.
resource "gitea_repository_branch_protection" "main" {
  for_each             = { for name, repo in var.extra_repositories : name => repo if repo.protect_main }
  username             = var.gitea_org
  name                 = gitea_repository.extra[each.key].name
  rule_name            = "main"
  enable_push          = true
  push_whitelist_users = ["gitops"]
  required_approvals   = 0

  dismiss_stale_approvals = true
}

# Argo CD reads the repositories it deploys from.
resource "gitea_repository_collaborator" "argocd_reader" {
  for_each   = { for name, repo in var.extra_repositories : name => repo if repo.argocd_read }
  owner      = var.gitea_org
  repo       = gitea_repository.extra[each.key].name
  username   = "xenomit-argocd"
  permission = "read"
}

# Gitea does the mirroring itself: every branch and tag keeps its name. Gitea cannot edit a
# push mirror and never returns its password, so any change recreates it.
resource "restapi_object" "github_mirror" {
  for_each     = local.github_enabled ? var.github_mirrors : {}
  path         = "/repos/${var.gitea_org}/${each.key}/push_mirrors"
  id_attribute = "remote_name"

  data = jsonencode({
    remote_address  = each.value
    remote_username = var.github_mirror_username
    remote_password = var.github_mirror_token
    interval        = "8h0m0s"
    sync_on_commit  = true
  })
  force_new = [sha256(jsonencode([each.value, var.github_mirror_username, var.github_mirror_token]))]

  ignore_all_server_changes = true
  depends_on                = [gitea_repository.extra]
}

# The release workflow of those repositories publishes to GitHub with this token.
resource "gitea_repository_actions_secret" "release_github_token" {
  for_each         = local.github_enabled ? var.release_secret_repositories : toset([])
  repository_owner = var.gitea_org
  repository       = each.key
  secret_name      = "RELEASE_GITHUB_TOKEN"
  secret_value     = var.github_mirror_token
  depends_on       = [gitea_repository.extra]
}
