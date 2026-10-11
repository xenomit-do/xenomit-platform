# Repositories whose local checkout the bootstrap pushes to Gitea right after this stack.
output "seed_repositories" {
  value = sort(keys(gitea_repository.extra))
}
