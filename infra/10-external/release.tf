resource "github_repository_environment" "platform_release" {
  repository  = github_repository.managed["xenomit-platform"].name
  environment = "platform-release"
  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }
}
resource "github_actions_environment_secret" "deployments" {
  count           = try(var.config.deployment_token, "") != "" ? 1 : 0
  repository      = github_repository.managed["xenomit-platform"].name
  environment     = github_repository_environment.platform_release.environment
  secret_name     = "DEPLOYMENTS_TOKEN"
  plaintext_value = var.config.deployment_token
}
