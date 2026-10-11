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

variable "vault_address" {
  description = "Vault as seen from the host."
  type        = string
  default     = "https://127.0.0.1:8200"
}

variable "node_cidr" {
  description = "Subnet of the k3d docker network (node IPs). Supplied by ops/bootstrap.ps1."
  type        = string
}

variable "vault_host_ip" {
  description = "IP that host.k3d.internal resolves to inside the cluster. Supplied by ops/bootstrap.ps1."
  type        = string
}
