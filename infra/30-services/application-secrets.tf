resource "tls_private_key" "api" {
  algorithm = "ED25519"
}
resource "random_password" "panel_auth" {
  length  = 64
  special = false
}
resource "random_password" "panel_service" {
  length  = 64
  special = false
}
resource "kubernetes_secret_v1" "api" {
  metadata {
    name      = "xenomit-api-jwt"
    namespace = "xenomit-system"
  }
  data = {
    "jwt-public.pem"  = tls_private_key.api.public_key_pem
    "jwt-private.pem" = tls_private_key.api.private_key_pem
    "service-token"   = random_password.panel_service.result
  }
}
resource "kubernetes_secret_v1" "panel" {
  metadata {
    name      = "xenomit-panel-auth"
    namespace = "xenomit-system"
  }
  data = {
    AUTH_SECRET                = random_password.panel_auth.result
    ORCHESTRATOR_SERVICE_TOKEN = random_password.panel_service.result
  }
}
resource "kubernetes_secret_v1" "database_urls" {
  metadata {
    name      = "postgres-auth"
    namespace = "xenomit-system"
  }
  data = {
    "orchestrator-url" = "postgres://xenomit:${random_password.postgres.result}@postgres.xenomit-data:5432/xenomit_orchestrator"
    "panel-url"        = "postgresql://xenomit:${random_password.postgres.result}@postgres.xenomit-data:5432/xenomit_panel?schema=public"
  }
}
