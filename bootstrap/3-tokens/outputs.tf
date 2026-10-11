# Every output of every stage becomes an input variable of the later stacks that
# declare a variable with the same name (see ops/bootstrap.ps1).

# Admin token for the applies that run from the host.
output "gitea_token" {
  value     = gitea_token.admin.token
  sensitive = true
}

output "atlantis_webhook_secret" {
  value     = data.kubernetes_secret.gitea_service_users.data["webhook-secret"]
  sensitive = true
}

output "argocd_auth_token" {
  value     = argocd_account_token.tofu.jwt
  sensitive = true
}
