terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  # Local state, like the other bootstrap stages.

  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "= 2.38.0" }
    kubectl    = { source = "alekc/kubectl", version = "= 2.1.3" }
    vault      = { source = "hashicorp/vault", version = ">= 4.5.0, < 6.0.0" }
  }
}

provider "kubernetes" {
  config_path    = pathexpand(var.kube_config_path)
  config_context = var.kube_context
}

provider "kubectl" {
  load_config_file = true
  config_path      = pathexpand(var.kube_config_path)
  config_context   = var.kube_context
}

# Vault runs in Docker beside the cluster. The ops token is the one written to
# cluster-keys.json by ops/vault/vault-init.ps1 (the root token is revoked).
provider "vault" {
  address          = var.vault_address
  ca_cert_file     = abspath("${path.module}/../../ops/vault/tls/ca.crt")
  token            = local.vault_ops_token
  skip_child_token = true
}
