terraform {
  required_version = "= 1.12.6"
  backend "kubernetes" {
    namespace         = "atlantis-state"
    secret_suffix     = "xenomit-vault"
    in_cluster_config = true
  }
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "= 2.38.0" }
    vault      = { source = "hashicorp/vault", version = "= 5.3.0" }
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
variable "vault_address" {
  type    = string
  default = "http://vault.xenomit-system.svc.cluster.local:8200"
}
provider "kubernetes" {
  config_path    = var.kube_config_path
  config_context = var.kube_context
}
data "kubernetes_secret_v1" "vault" {
  metadata {
    name      = "vault-admin"
    namespace = "xenomit-system"
  }
}
provider "vault" {
  address = var.vault_address
  token   = data.kubernetes_secret_v1.vault.data["token"]
}
