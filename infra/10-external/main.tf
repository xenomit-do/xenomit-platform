locals {
  catalog  = jsondecode(file("${path.module}/../../repositories.json"))
  repos    = local.catalog.repositories
  org      = local.catalog.organization
  hostname = "atlantis.${var.config.domain}"
  # Interactive UIs exposed through the same tunnel. Each gets a CNAME, an
  # ingress rule ahead of the atlantis /events rule, and a self-hosted Access
  # application gated to the platform owner email.
  exposed_apps = {
    argocd  = "http://argocd-server.argocd.svc.cluster.local"
    vault   = "http://vault.xenomit-system.svc.cluster.local:8200"
    observe = "http://openobserve.observability.svc.cluster.local:5080"
    panel   = "http://web-panel.xenomit-system.svc.cluster.local:3000"
  }
  access_email = "y.kaan.aydogdu@gmail.com"
}
data "kubernetes_secret_v1" "credentials" {
  metadata {
    name      = "platform-credentials"
    namespace = "ci"
  }
}
provider "github" {
  owner = local.org
  token = var.config.github_admin_token
}
provider "cloudflare" {
  api_token = var.config.cloudflare_token
}
resource "github_repository" "managed" {
  for_each               = local.repos
  name                   = each.key
  visibility             = "public"
  archived               = each.value.archived
  auto_init              = true
  allow_merge_commit     = true
  allow_squash_merge     = true
  allow_rebase_merge     = false
  delete_branch_on_merge = true
  has_issues             = true
  has_wiki               = true
  archive_on_destroy     = true
  lifecycle {
    prevent_destroy = false # TEMPORARY: retiring Gitea repos; restored in follow-up PR
    precondition {
      condition = !contains(data.github_repositories.private.names, each.key) || try(
        var.config.publication_audits[each.key].reviewed_private_data &&
        var.config.publication_audits[each.key].secret_scan_passed &&
      var.config.publication_audits[each.key].github_head == data.github_branch.private[each.key].sha, false)
      error_message = "Private repository needs a current publication audit before becoming public."
    }
  }

}
resource "github_branch_default" "managed" {
  for_each   = local.repos
  repository = github_repository.managed[each.key].name
  branch     = each.value.default_branch
}
resource "github_branch_protection" "managed" {
  for_each = { for name, repo in local.repos : name => repo if !repo.archived
  }
  repository_id                   = github_repository.managed[each.key].node_id
  pattern                         = each.value.default_branch
  enforce_admins                  = true
  allows_deletions                = false
  allows_force_pushes             = false
  require_conversation_resolution = true
  required_pull_request_reviews {
    required_approving_review_count = 0
    dismiss_stale_reviews           = true
  }
  dynamic "required_status_checks" {
    for_each = length(each.value.required_checks) > 0 || each.value.atlantis ? [true] : []
    content {
      strict   = true
      contexts = concat(each.value.required_checks, each.value.atlantis ? ["atlantis/plan", "atlantis/apply"] : [])
    }
  }
}
resource "github_team" "maintainers" {
  name    = var.config.maintainer_team
  privacy = "closed"
  lifecycle {
    prevent_destroy = true
  }
}
resource "github_team_membership" "maintainers" {
  for_each = toset(var.config.maintainers)
  team_id  = github_team.maintainers.id
  username = each.key
  role     = "maintainer"
}
resource "github_team_repository" "maintainers" {
  for_each   = local.repos
  team_id    = github_team.maintainers.id
  repository = github_repository.managed[each.key].name
  permission = "maintain"
}
resource "github_repository_webhook" "atlantis" {
  for_each = { for name, repo in local.repos : name => repo if repo.atlantis && !repo.archived
  }
  repository = github_repository.managed[each.key].name
  events     = ["pull_request", "issue_comment", "push", "pull_request_review"]
  active     = true
  configuration {
    url          = "https://${local.hostname}/events"
    content_type = "json"
    insecure_ssl = false
    secret       = data.kubernetes_secret_v1.credentials.data["ATLANTIS_GH_WEBHOOK_SECRET"]
  }
}
resource "cloudflare_zero_trust_tunnel_cloudflared" "atlantis" {
  account_id = var.config.cloudflare_account_id
  name       = try(var.config.tunnel_name, "xenomit-${var.config.environment_id}-atlantis")
  secret     = data.kubernetes_secret_v1.credentials.data["TUNNEL_SECRET"]
  config_src = "cloudflare"
  lifecycle {
    prevent_destroy = true
    # Provider v4 import omits config_src; retain the existing remote tunnel.
    ignore_changes = [secret, config_src]
  }
}
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "atlantis" {
  account_id = var.config.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.atlantis.id
  config {
    dynamic "ingress_rule" {
      for_each = local.exposed_apps
      content {
        hostname = "${ingress_rule.key}.${var.config.domain}"
        service  = ingress_rule.value
      }
    }
    ingress_rule {
      hostname = local.hostname
      path     = "^/events$"
      service  = "http://atlantis.ci.svc.cluster.local:4141"
    }
    ingress_rule {
      service = "http_status:404"
    }
  }
}
resource "cloudflare_record" "apps" {
  for_each = local.exposed_apps
  zone_id  = var.config.cloudflare_zone_id
  name     = each.key
  type     = "CNAME"
  content  = "${cloudflare_zero_trust_tunnel_cloudflared.atlantis.id}.cfargotunnel.com"
  proxied  = true
  ttl      = 1
}
resource "cloudflare_zero_trust_access_application" "apps" {
  for_each             = local.exposed_apps
  account_id           = var.config.cloudflare_account_id
  name                 = each.key
  domain               = "${each.key}.${var.config.domain}"
  type                 = "self_hosted"
  session_duration     = "24h"
  app_launcher_visible = true
  skip_interstitial    = true
}
resource "cloudflare_zero_trust_access_policy" "apps" {
  for_each       = local.exposed_apps
  account_id     = var.config.cloudflare_account_id
  application_id = cloudflare_zero_trust_access_application.apps[each.key].id
  name           = "owner"
  precedence     = 1
  decision       = "allow"
  include {
    email = [local.access_email]
  }
}
resource "cloudflare_record" "atlantis" {
  zone_id = var.config.cloudflare_zone_id
  name    = "atlantis"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.atlantis.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  lifecycle {
    prevent_destroy = true
  }
}
resource "kubernetes_secret_v1" "tunnel" {
  metadata {
    name      = "cloudflare-tunnel"
    namespace = "ci"
  }
  data = {
    token = cloudflare_zero_trust_tunnel_cloudflared.atlantis.tunnel_token
  }
}

data "github_repositories" "private" {
  query = "org:${local.org} is:private"
}
data "github_branch" "private" {
  for_each   = toset([for name in data.github_repositories.private.names : name if contains(keys(local.repos), name)])
  repository = each.key
  branch     = local.repos[each.key].default_branch
}
resource "github_repository_environment" "fork_ci" {
  for_each = { for name, repo in local.repos : name => repo if !repo.archived
  }
  repository          = github_repository.managed[each.key].name
  environment         = "fork-ci"
  prevent_self_review = true
  reviewers {
    users = var.config.maintainer_ids
  }
}
resource "github_organization_settings" "managed" {
  billing_email                            = var.config.billing_email
  members_can_create_repositories          = false
  members_can_create_public_repositories   = false
  members_can_create_private_repositories  = false
  members_can_create_internal_repositories = false
}
