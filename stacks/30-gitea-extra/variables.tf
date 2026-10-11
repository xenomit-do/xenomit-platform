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
  description = "Gitea as seen from the host."
  type        = string
  default     = "http://127.0.0.1:3000"
}

variable "gitea_org" {
  description = "Gitea organization that owns the repositories."
  type        = string
  default     = "xenomit"
}

variable "extra_repositories" {
  description = "Repositories that are not platform infrastructure. Add one here to create it, protect main, and (below) mirror it."
  type = map(object({
    description  = string
    argocd_read  = bool # Argo CD may read it
    protect_main = bool # changes reach main through pull requests only
  }))
  default = {
    "xenomit-flash-client-linux" = {
      description  = "Linux host for Pepper Flash used by the bots."
      argocd_read  = false
      protect_main = true
    }
    "xenomit-deployments" = {
      description  = "Deployment sources that Argo CD syncs from."
      argocd_read  = true
      protect_main = false # CI will promote image digests into it; add a push whitelist before protecting
    }
  }
}

variable "github_mirrors" {
  description = "Gitea repository => GitHub repository URL. Gitea pushes every branch and tag there under the same name."
  type        = map(string)
  default = {
    "xenomit-flash-client-linux" = "https://github.com/xenomit-do/xenomit-flash-client-linux.git"
  }
}

variable "release_secret_repositories" {
  description = "Repositories whose Gitea Actions receive the GitHub token as secret RELEASE_GITHUB_TOKEN, to publish GitHub releases."
  type        = set(string)
  default     = ["xenomit-flash-client-linux"]
}

variable "github_mirror_token" {
  description = "GitHub token, from stacks/10-github-token. null = no mirrors and no release secrets."
  type        = string
  sensitive   = true
  default     = null
}

variable "github_mirror_username" {
  description = "GitHub user the token belongs to."
  type        = string
  default     = "ykaydogdu"
}
