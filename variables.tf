variable "argocd_server" {
  description = "In-cluster ArgoCD API endpoint."
  type        = string
  default     = "argocd-server.argocd.svc.cluster.local:80"
}

variable "argocd_auth_token" {
  description = "xenomit-tofu API token supplied by Atlantis."
  type        = string
  sensitive   = true
}

variable "cluster_server" {
  description = "In-cluster Kubernetes API server."
  type        = string
  default     = "https://kubernetes.default.svc"
}

variable "git_base" {
  description = "In-cluster Gitea origin."
  type        = string
  default     = "http://gitea.git.svc.cluster.local:3000"
}

variable "kube_config_path" {
  description = "kubeconfig for runs outside the cluster. null = in-cluster ServiceAccount (Atlantis)."
  type        = string
  default     = null
}

variable "kube_context" {
  description = "kubeconfig context; only used together with kube_config_path."
  type        = string
  default     = null
}
