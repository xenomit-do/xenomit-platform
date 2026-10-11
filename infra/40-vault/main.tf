data "kubernetes_config_map_v1" "ca" {
  metadata {
    name      = "kube-root-ca.crt"
    namespace = "xenomit-system"
  }
}
resource "vault_jwt_auth_backend" "jwt" {
  path         = "jwt"
  type         = "jwt"
  jwks_url     = "${var.config.jwt_issuer}/openid/v1/jwks"
  jwks_ca_pem  = data.kubernetes_config_map_v1.ca.data["ca.crt"]
  bound_issuer = var.config.jwt_issuer
}
resource "vault_policy" "orchestrator" {
  name   = "orchestrator"
  policy = file("${path.module}/../../ops/vault/policies/orchestrator.hcl")
}
resource "vault_jwt_auth_backend_role" "orchestrator" {
  backend         = vault_jwt_auth_backend.jwt.path
  role_name       = "orchestrator"
  role_type       = "jwt"
  user_claim      = "sub"
  bound_audiences = ["vault"]
  bound_subject   = "system:serviceaccount:xenomit-system:orchestrator"
  token_policies  = [vault_policy.orchestrator.name]
  token_ttl       = 900
  token_max_ttl   = 3600
}
