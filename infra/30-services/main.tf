provider "helm" {
  kubernetes {
    config_path    = var.kube_config_path
    config_context = var.kube_context
  }
}
provider "kubectl" {
  load_config_file = var.kube_config_path != null
  config_path      = var.kube_config_path
  config_context   = var.kube_context
}
locals {
  source_root = "${path.module}/../.."
}
