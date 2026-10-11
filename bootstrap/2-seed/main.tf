# Stage 2: the minimum Gitea needs before anything else can be applied from git:
# the organization, the two service users, and the (empty) platform repositories.
# Everything else about Gitea is OpenTofu in the repositories themselves
# (xenomit-platform-gitea for the platform repositories, stacks/ for the rest).

data "kubernetes_secret" "gitops" {
  metadata {
    name      = "gitops-git"
    namespace = "git"
  }
}

data "kubernetes_secret" "gitea_service_users" {
  metadata {
    name      = "gitea-service-users"
    namespace = "git"
  }
}

resource "gitea_org" "xenomit" {
  name       = var.gitea_org
  visibility = "private"
}

# Neither is an organization owner. Atlantis gets its access from the platform-infra
# team (xenomit-platform-gitea), Argo CD from read collaborators.
resource "gitea_user" "atlantis" {
  username             = "atlantis"
  login_name           = "atlantis"
  email                = "atlantis@xenomit.local"
  password             = data.kubernetes_secret.gitea_service_users.data["atlantis-password"]
  must_change_password = false
}

resource "gitea_user" "argocd_reader" {
  username             = "xenomit-argocd"
  login_name           = "xenomit-argocd"
  email                = "argocd@xenomit.local"
  password             = data.kubernetes_secret.gitea_service_users.data["argocd-reader-password"]
  must_change_password = false
}

# Created empty. Settings, webhooks and branch protection belong to the
# xenomit-platform-gitea stack, which imports these repositories afterwards, so
# this stack must never fight it over their settings.
resource "gitea_repository" "managed" {
  for_each       = var.repositories
  username       = gitea_org.xenomit.name
  name           = each.key
  private        = true
  default_branch = "main"
  auto_init      = false

  lifecycle {
    ignore_changes = all
  }
}

resource "gitea_repository_collaborator" "argocd_reader" {
  for_each   = toset(["xenomit-platform", "xenomit-platform-argocd"])
  owner      = gitea_org.xenomit.name
  repo       = gitea_repository.managed[each.key].name
  username   = gitea_user.argocd_reader.username
  permission = "read"
}

# Moved to stacks/30-gitea-extra. Forget them here without deleting anything, so an
# older state cannot destroy those repositories. Delete these blocks once every
# machine has been rebuilt from scratch.
removed {
  from = gitea_repository.extra
  lifecycle {
    destroy = false
  }
}

removed {
  from = gitea_repository_branch_protection.extra_main
  lifecycle {
    destroy = false
  }
}

removed {
  from = gitea_repository_collaborator.argocd_reader_extra
  lifecycle {
    destroy = false
  }
}

removed {
  from = gitea_team_membership.atlantis_owner
  lifecycle {
    destroy = false
  }
}
