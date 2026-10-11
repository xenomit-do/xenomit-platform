terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  # Local state (bootstrap/1-services/terraform.tfstate). The cluster this stack
  # builds is disposable, so its state is disposable with it.

  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "= 2.38.0" }
    kubectl    = { source = "alekc/kubectl", version = "= 2.1.3" }
    helm       = { source = "hashicorp/helm", version = "= 2.17.0" }
    random     = { source = "hashicorp/random", version = "= 3.6.3" }
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

provider "helm" {
  kubernetes {
    config_path    = pathexpand(var.kube_config_path)
    config_context = var.kube_context
  }
}
