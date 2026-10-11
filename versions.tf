terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  # State is a Secret in the cluster. Atlantis uses it as written here; the host
  # bootstrap overrides in_cluster_config/config_path/config_context with
  # `tofu init -backend-config=...` and reaches the very same Secret.
  backend "kubernetes" {
    namespace         = "atlantis-state"
    secret_suffix     = "xenomit-platform"
    in_cluster_config = true
  }

  required_providers {
    kubectl = {
      source  = "alekc/kubectl"
      version = "= 2.1.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 2.38.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "= 2.17.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "= 3.6.3"
    }
    argocd = {
      source  = "argoproj-labs/argocd"
      version = "= 7.17.1"
    }
  }
}

# In the cluster (Atlantis) the providers use the pod's ServiceAccount.
# ops/bootstrap.ps1 runs the first apply from the host and sets kube_config_path.
provider "kubectl" {
  load_config_file = var.kube_config_path != null
  config_path      = var.kube_config_path == null ? null : pathexpand(var.kube_config_path)
  config_context   = var.kube_context
}

provider "kubernetes" {
  config_path    = var.kube_config_path == null ? null : pathexpand(var.kube_config_path)
  config_context = var.kube_context
}

provider "helm" {
  kubernetes {
    config_path    = var.kube_config_path == null ? null : pathexpand(var.kube_config_path)
    config_context = var.kube_context
  }
}

provider "argocd" {
  server_addr = var.argocd_server
  auth_token  = var.argocd_auth_token
  plain_text  = true
  grpc_web    = true
}
