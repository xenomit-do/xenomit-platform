variable "kube_config_path" {
  description = "kubeconfig that holds the k3d context."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "kubectl context of the k3d cluster."
  type        = string
  default     = "k3d-xenomit"
}

variable "gitea_url" {
  description = "Gitea as seen from the host (loopback NodePort from ops/k3d/localhost-core.yaml)."
  type        = string
  default     = "http://127.0.0.1:3000"
}

variable "gitea_org" {
  description = "Gitea organization that owns the platform repositories."
  type        = string
  default     = "xenomit"
}

variable "repositories" {
  description = "Platform repositories created empty here; contents are pushed by ops/bootstrap.ps1."
  type        = set(string)
  default     = ["xenomit-platform", "xenomit-platform-gitea", "xenomit-platform-argocd"]
}
