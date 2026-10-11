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

variable "github_token_file" {
  description = "Optional. File with a GitHub token. When set, it is written to Vault (secret/infra/github-mirror) and everything below it is wired. Without it no GitHub mirrors or releases are configured."
  type        = string
  default     = null
}

variable "github_username" {
  description = "GitHub user the token belongs to."
  type        = string
  default     = "ykaydogdu"
}
