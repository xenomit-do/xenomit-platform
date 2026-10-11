terraform {
  required_version = "= 1.12.6"
  backend "kubernetes" {
    namespace         = "atlantis-state"
    secret_suffix     = "xenomit-external"
    in_cluster_config = true
  }
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes", version = "= 2.38.0"
    }
    random = { source = "hashicorp/random", version = "= 3.6.3"
    }
    github = { source = "integrations/github", version = "= 6.13.0"
    }
    cloudflare = { source = "cloudflare/cloudflare", version = "= 4.52.0"
    }
  }
}
variable "config" {
  type = any
}
variable "kube_config_path" {
  type    = string
  default = null
}
variable "kube_context" {
  type    = string
  default = null
}
provider "kubernetes" {
  config_path    = var.kube_config_path
  config_context = var.kube_context
}
