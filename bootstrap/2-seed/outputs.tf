# Every output of every stage becomes an input variable of the later stacks that
# declare a variable with the same name (see ops/bootstrap.ps1).

output "gitops_password" {
  value     = data.kubernetes_secret.gitops.data["password"]
  sensitive = true
}

# Numeric Gitea ids, imported by the xenomit-platform-gitea stack.
output "import_repository_ids" {
  value = { for name, repo in gitea_repository.managed : name => repo.id }
}

# Repositories whose local checkout the bootstrap pushes to Gitea right after this stage.
output "seed_repositories" {
  value = sort(keys(gitea_repository.managed))
}
