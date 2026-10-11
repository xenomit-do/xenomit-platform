terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  # Local state, like the other bootstrap stages.

  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "= 2.38.0" }
    gitea      = { source = "go-gitea/gitea", version = "= 0.8.1" }
  }
}

provider "kubernetes" {
  config_path    = pathexpand(var.kube_config_path)
  config_context = var.kube_context
}

# Site admin: creates the organization, the users and the repositories.
provider "gitea" {
  base_url = var.gitea_url
  username = "gitops"
  password = data.kubernetes_secret.gitops.data["password"]
}
