resource "github_repository_environment" "platform_admin" {
  repository  = github_repository.managed["xenomit-platform"].name
  environment = "platform-admin"
  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }
}
resource "github_actions_environment_secret" "reconcile" {
  repository      = github_repository.managed["xenomit-platform"].name
  environment     = github_repository_environment.platform_admin.environment
  secret_name     = "RECONCILE_TOKEN"
  plaintext_value = var.config.github_admin_token
}
resource "github_actions_runner_group" "build" {
  restricted_to_workflows = true
  selected_workflows = [
    "xenomit-do/xenomit-platform/.github/workflows/source-check.yml@refs/heads/main",
    "xenomit-do/xenomit-platform/.github/workflows/images.yml@refs/heads/main"
  ]
  name                       = "xenomit-build"
  visibility                 = "selected"
  allows_public_repositories = true
  selected_repository_ids    = [for repo in github_repository.managed : repo.repo_id]
}
resource "github_actions_runner_group" "platform" {
  restricted_to_workflows = true
  selected_workflows = [
    "xenomit-do/xenomit-platform/.github/workflows/platform-check.yml@refs/heads/main",
    "xenomit-do/xenomit-platform/.github/workflows/catalog.yml@refs/heads/main",
    "xenomit-do/xenomit-platform/.github/workflows/images.yml@refs/heads/main"
  ]
  name                       = "xenomit-platform"
  visibility                 = "selected"
  allows_public_repositories = true
  selected_repository_ids    = [github_repository.managed["xenomit-platform"].repo_id, github_repository.managed["xenomit-deployments"].repo_id]
}
