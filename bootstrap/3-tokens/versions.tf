terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  # Local state, like the other bootstrap stages.

  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "= 2.38.0" }
    kubectl    = { source = "alekc/kubectl", version = "= 2.1.3" }
    gitea      = { source = "go-gitea/gitea", version = "= 0.8.1" }
    argocd     = { source = "argoproj-labs/argocd", version = "= 7.17.1" }
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

# The Gitea provider logs in when it is configured, and a token can only be
# minted by the user it belongs to. That is why this is a separate stage: the
# users below were created by stage 2 and must exist before OpenTofu starts.
provider "gitea" {
  alias    = "atlantis"
  base_url = var.gitea_url
  username = "atlantis"
  password = data.kubernetes_secret.gitea_service_users.data["atlantis-password"]
}

provider "gitea" {
  alias    = "argocd_reader"
  base_url = var.gitea_url
  username = "xenomit-argocd"
  password = data.kubernetes_secret.gitea_service_users.data["argocd-reader-password"]
}

provider "argocd" {
  server_addr = var.argocd_server
  username    = "admin"
  password    = data.kubernetes_secret.argocd_accounts.data["admin-password"]
  plain_text  = true
  grpc_web    = true
}

# Site admin: mints the admin token for the applies that run from the host.
provider "gitea" {
  base_url = var.gitea_url
  username = "gitops"
  password = data.kubernetes_secret.gitops.data["password"]
}
