# The GitHub token. Vault is where it is kept and rotated. Gitea cannot read Vault and
# neither does Atlantis, so this stack reads it back and hands it on:
#   * as Secret ci/atlantis-mirror, which Atlantis turns into TF_VAR_github_mirror_token
#     for the mirrors in xenomit-platform-gitea (pull requests, day 2)
#   * as the outputs below, which ops/bootstrap.ps1 gives to the later stacks that declare
#     a variable of the same name (the first apply from the host)

locals {
  # cluster-keys.json is written by PowerShell and starts with a UTF-8 BOM.
  vault_ops_token = jsondecode(trimprefix(file("${path.module}/../../ops/vault/cluster-keys.json"), "\ufeff")).ops_token
  enabled         = var.github_token_file != null
}

resource "vault_kv_secret_v2" "github_mirror" {
  count = local.enabled ? 1 : 0
  mount = "secret"
  name  = "infra/github-mirror"
  data_json = jsonencode({
    username = var.github_username
    token    = trimspace(file(var.github_token_file))
  })
}

data "vault_kv_secret_v2" "github_mirror" {
  count      = local.enabled ? 1 : 0
  mount      = "secret"
  name       = "infra/github-mirror"
  depends_on = [vault_kv_secret_v2.github_mirror]
}

resource "kubernetes_secret" "atlantis_mirror" {
  count = local.enabled ? 1 : 0
  metadata {
    name      = "atlantis-mirror"
    namespace = "ci"
  }
  data = {
    GITHUB_MIRROR_USERNAME = data.vault_kv_secret_v2.github_mirror[0].data["username"]
    GITHUB_MIRROR_TOKEN    = data.vault_kv_secret_v2.github_mirror[0].data["token"]
  }
}

# Environment variables are read when a pod starts, so a changed token needs a restart.
resource "terraform_data" "atlantis_restart" {
  count            = local.enabled ? 1 : 0
  triggers_replace = [sha256(kubernetes_secret.atlantis_mirror[0].data["GITHUB_MIRROR_TOKEN"])]

  provisioner "local-exec" {
    command = "kubectl --context ${var.kube_context} -n ci rollout restart deploy/atlantis"
  }
}
