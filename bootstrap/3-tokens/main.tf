# Stage 3: mint the tokens everything else uses and start Atlantis.
# Needs the users and repositories from stage 2.

locals {
  ops = "${path.module}/../../ops"
}

data "kubernetes_secret" "gitea_service_users" {
  metadata {
    name      = "gitea-service-users"
    namespace = "git"
  }
}

data "kubernetes_secret" "gitops" {
  metadata {
    name      = "gitops-git"
    namespace = "git"
  }
}

data "kubernetes_secret" "argocd_accounts" {
  metadata {
    name      = "argocd-local-accounts"
    namespace = "argocd"
  }
}

# ---- tokens -----------------------------------------------------------------

resource "gitea_token" "atlantis" {
  provider = gitea.atlantis
  name     = "atlantis"
  # write:issue is what lets Atlantis comment its plan output on pull requests.
  scopes = ["write:repository", "write:organization", "write:issue", "read:user"]
}

# Token of the gitops admin, for the applies that run from the host (the first apply of
# xenomit-platform-gitea and the stacks). Atlantis never receives it: it uses its own,
# much narrower token and is not an organization owner.
resource "gitea_token" "admin" {
  name   = "bootstrap-admin"
  scopes = ["all"]
}

resource "gitea_token" "argocd_reader" {
  provider = gitea.argocd_reader
  name     = "argocd-readonly"
  scopes   = ["read:repository"]
}

# Argo CD API token for OpenTofu and Atlantis (account xenomit-tofu, defined in
# ops/argocd/argocd-values-local.yaml).
resource "argocd_account_token" "tofu" {
  account = "xenomit-tofu"
}

# ---- Secrets consumed by Atlantis and Argo CD -----------------------------------

resource "kubernetes_secret" "atlantis_vcs" {
  metadata {
    name      = "atlantis-vcs"
    namespace = "ci"
  }
  data = {
    ATLANTIS_GITEA_USER           = "atlantis"
    ATLANTIS_GITEA_TOKEN          = gitea_token.atlantis.token
    ATLANTIS_GITEA_WEBHOOK_SECRET = data.kubernetes_secret.gitea_service_users.data["webhook-secret"]
  }
}

resource "kubernetes_secret" "atlantis_iac" {
  metadata {
    name      = "atlantis-iac"
    namespace = "ci"
  }
  data = {
    ARGOCD_AUTH_TOKEN = argocd_account_token.tofu.jwt
  }
}

# Argo CD reads every repository under this URL prefix with the read-only token.
resource "kubernetes_secret" "argocd_repo_creds" {
  metadata {
    name      = "gitea-xenomit-repo-creds"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repo-creds"
    }
  }
  data = {
    type     = "git"
    url      = "http://gitea.git.svc.cluster.local:3000/"
    username = "xenomit-argocd"
    password = gitea_token.argocd_reader.token
  }
}

# ---- Gitea Actions runner ---------------------------------------------------------
# The runner (xenomit-platform-argocd, deploy/runner) registers itself with this token and
# mounts it from Secret xenomit-actions-runner-token. Without the Secret its pod stays in
# ContainerCreating and no workflow ever runs. An organization token lets one runner serve
# every repository of the organization.
data "gitea_actions_runner_registration_token" "org" {
  scope = "org"
  org   = "xenomit"
}

resource "kubernetes_secret" "actions_runner_token" {
  metadata {
    name      = "xenomit-actions-runner-token"
    namespace = "ci"
  }
  data = {
    token = data.gitea_actions_runner_registration_token.org.token
  }
}

# ---- Atlantis ---------------------------------------------------------------

data "kubectl_file_documents" "atlantis" {
  content = join("\n---\n", [
    file("${local.ops}/argocd/atlantis.yaml"),
    file("${local.ops}/argocd/atlantis-rbac.yaml"),
  ])
}

resource "kubectl_manifest" "atlantis" {
  for_each  = data.kubectl_file_documents.atlantis.manifests
  yaml_body = each.value

  depends_on = [kubernetes_secret.atlantis_vcs, kubernetes_secret.atlantis_iac]
}

# Environment variables are read when a pod starts, so changed tokens need a restart.
resource "terraform_data" "atlantis_restart" {
  triggers_replace = [
    sha256(gitea_token.atlantis.token),
    sha256(argocd_account_token.tofu.jwt),
  ]

  provisioner "local-exec" {
    command = "kubectl --context ${var.kube_context} -n ci rollout restart deploy/atlantis"
  }

  depends_on = [kubectl_manifest.atlantis, kubernetes_secret.atlantis_vcs, kubernetes_secret.atlantis_iac]
}

# Moved to stacks/10-github-token and stacks/30-gitea-extra. Forget them here without
# deleting anything. Delete these blocks once every machine has been rebuilt from scratch.
removed {
  from = vault_kv_secret_v2.github_mirror
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_secret.atlantis_mirror
  lifecycle {
    destroy = false
  }
}

removed {
  from = restapi_object.extra_github_mirror
  lifecycle {
    destroy = false
  }
}

removed {
  from = gitea_repository_actions_secret.release_github_token
  lifecycle {
    destroy = false
  }
}
