terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  # Local state. Admin stack: applied from the host by ops/bootstrap.ps1 with the gitops
  # admin account, not by Atlantis. Atlantis has no access to the repositories below.

  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "= 2.38.0" }
    gitea      = { source = "go-gitea/gitea", version = "= 0.8.1" }
    restapi    = { source = "Mastercard/restapi", version = "= 2.0.1" }
  }
}

provider "kubernetes" {
  config_path    = pathexpand(var.kube_config_path)
  config_context = var.kube_context
}

provider "gitea" {
  base_url = var.gitea_url
  username = "gitops"
  password = data.kubernetes_secret.gitops.data["password"]
}

provider "restapi" {
  uri                   = "${var.gitea_url}/api/v1"
  username              = "gitops"
  password              = data.kubernetes_secret.gitops.data["password"]
  headers               = { "Content-Type" = "application/json" }
  write_returns_object  = true
  create_returns_object = true
}
