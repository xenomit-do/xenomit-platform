locals {
  namespaces = toset(["argocd", "ci", "arc-system", "arc-build", "arc-platform", "xenomit-system", "xenomit-bots", "xenomit-data", "observability", "kyverno"])
}
resource "kubernetes_namespace_v1" "managed" {
  for_each = local.namespaces
  metadata {
    name = each.key
  }
}
resource "random_password" "webhook" {
  length  = 64
  special = false
}
resource "random_password" "tunnel" {
  length  = 32
  special = false
}
resource "kubernetes_secret_v1" "credentials" {
  metadata {
    name      = "platform-credentials"
    namespace = "ci"
  }
  data = {
    GITHUB_TOKEN                = var.config.github_admin_token
    CLOUDFLARE_API_TOKEN        = var.config.cloudflare_token
    ATLANTIS_GH_APP_ID          = var.config.atlantis_app_id
    ATLANTIS_GH_INSTALLATION_ID = var.config.atlantis_installation_id
    "atlantis.pem"              = var.config.atlantis_app_key
    ATLANTIS_GH_WEBHOOK_SECRET  = random_password.webhook.result
    TUNNEL_SECRET               = base64encode(random_password.tunnel.result)
    "config.json"               = jsonencode({ config = var.config })
  }
  depends_on = [kubernetes_namespace_v1.managed]
}
resource "kubernetes_secret_v1" "arc" {
  for_each = toset(["arc-build", "arc-platform"])
  metadata {
    name      = "github-arc"
    namespace = each.key
  }
  data = {
    github_app_id              = var.config.arc_app_id
    github_app_installation_id = var.config.arc_installation_id
    github_app_private_key     = var.config.arc_app_key
  }
  depends_on = [kubernetes_namespace_v1.managed]
}
