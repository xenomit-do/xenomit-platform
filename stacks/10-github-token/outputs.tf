# Empty when no token file was given.
output "github_mirror_token" {
  value     = local.enabled ? data.vault_kv_secret_v2.github_mirror[0].data["token"] : ""
  sensitive = true
}

output "github_mirror_username" {
  value     = local.enabled ? data.vault_kv_secret_v2.github_mirror[0].data["username"] : ""
  sensitive = true # read from Vault, which OpenTofu treats as sensitive
}
