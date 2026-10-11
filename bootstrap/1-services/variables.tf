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

variable "argocd_chart_version" {
  description = "argo/argo-cd Helm chart version. Check `helm show values` before bumping."
  type        = string
  default     = "9.5.15"
}
