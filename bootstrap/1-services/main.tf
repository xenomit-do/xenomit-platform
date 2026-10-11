# Stage 1: everything that has to exist before Gitea and Argo CD can be talked to.
# Needs only kubectl access (the k3d cluster is created by ops/bootstrap.ps1).

locals {
  ops = "${path.module}/../../ops"
  labels = {
    "app.kubernetes.io/part-of" = "xenomit"
  }
}

# ---- namespaces -------------------------------------------------------------

resource "kubernetes_namespace" "this" {
  for_each = {
    git            = "git"
    argocd         = "argocd"
    ci             = "ci"
    atlantis-state = "iac-state"
  }
  metadata {
    name   = each.key
    labels = merge(local.labels, { "xenomit.io/role" = each.value })
  }
}

# ---- generated credentials (live in state and in Secrets, never in git) -----

resource "random_password" "gitops" {
  length  = 48
  special = false
}

resource "random_password" "atlantis_user" {
  length  = 48
  special = false
}

resource "random_password" "argocd_reader_user" {
  length  = 48
  special = false
}

resource "random_password" "webhook" {
  length  = 32
  special = false
}

resource "random_password" "argocd_admin" {
  length  = 48
  special = false
}

resource "random_password" "argocd_viewer" {
  length  = 48
  special = false
}

# bcrypt() picks a new salt on every evaluation. ignore_changes freezes the first
# result so the Helm release does not change on every plan.
resource "terraform_data" "argocd_hashes" {
  input = {
    admin  = bcrypt(random_password.argocd_admin.result)
    viewer = bcrypt(random_password.argocd_viewer.result)
    mtime  = timestamp()
  }
  lifecycle {
    ignore_changes = [input]
  }
}

resource "kubernetes_secret" "gitops" {
  metadata {
    name      = "gitops-git"
    namespace = kubernetes_namespace.this["git"].metadata[0].name
  }
  data = {
    username = "gitops"
    password = random_password.gitops.result
  }
}

# Passwords of the two Gitea service users. Stage 2 creates the users and logs in
# as them once to mint API tokens.
resource "kubernetes_secret" "gitea_service_users" {
  metadata {
    name      = "gitea-service-users"
    namespace = kubernetes_namespace.this["git"].metadata[0].name
  }
  data = {
    "atlantis-password"      = random_password.atlantis_user.result
    "argocd-reader-password" = random_password.argocd_reader_user.result
    "webhook-secret"         = random_password.webhook.result
  }
}

resource "kubernetes_secret" "argocd_local_accounts" {
  metadata {
    name      = "argocd-local-accounts"
    namespace = kubernetes_namespace.this["argocd"].metadata[0].name
  }
  data = {
    "admin-password"  = random_password.argocd_admin.result
    "viewer-password" = random_password.argocd_viewer.result
  }
}

# ---- Gitea ------------------------------------------------------------------

resource "kubernetes_config_map" "gitea_bootstrap" {
  metadata {
    name      = "gitea-bootstrap"
    namespace = kubernetes_namespace.this["git"].metadata[0].name
  }
  data = {
    "gitea-admin.sh" = file("${path.module}/gitea-admin.sh")
  }
}

data "kubectl_file_documents" "gitea" {
  content = file("${local.ops}/argocd/gitea.yaml")
}

resource "kubectl_manifest" "gitea" {
  for_each   = data.kubectl_file_documents.gitea.manifests
  yaml_body  = each.value
  depends_on = [kubernetes_secret.gitops, kubernetes_config_map.gitea_bootstrap]
}

# Create (or re-sync) the gitops admin inside the pod. Re-runs when its password
# or the script changes.
resource "terraform_data" "gitea_admin" {
  triggers_replace = [sha256(random_password.gitops.result), filesha256("${path.module}/gitea-admin.sh")]

  provisioner "local-exec" {
    command = "kubectl --context ${var.kube_context} -n git exec deploy/gitea -- sh /bootstrap/gitea-admin.sh"
  }

  depends_on = [kubectl_manifest.gitea]
}

# ---- Argo CD ----------------------------------------------------------------

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace.this["argocd"].metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  wait       = true
  timeout    = 600

  values = [
    file("${local.ops}/argocd/argocd-values-local.yaml"),
    # Account passwords go into the chart-managed argocd-secret.
    sensitive(yamlencode({
      configs = {
        secret = {
          argocdServerAdminPassword      = terraform_data.argocd_hashes.output.admin
          argocdServerAdminPasswordMtime = terraform_data.argocd_hashes.output.mtime
          extra = {
            "accounts.viewer.password"      = terraform_data.argocd_hashes.output.viewer
            "accounts.viewer.passwordMtime" = terraform_data.argocd_hashes.output.mtime
          }
        }
      }
    })),
  ]
}

# ---- loopback ports for Argo CD and Gitea ------------------------------------

data "kubectl_file_documents" "localhost_core" {
  content = file("${local.ops}/k3d/localhost-core.yaml")
}

resource "kubectl_manifest" "localhost_core" {
  for_each   = data.kubectl_file_documents.localhost_core.manifests
  yaml_body  = each.value
  depends_on = [kubectl_manifest.gitea, helm_release.argocd]
}

# ---- state Role for Atlantis ------------------------------------------------

data "kubectl_file_documents" "atlantis_state" {
  content = file("${local.ops}/argocd/atlantis-state.yaml")
}

resource "kubectl_manifest" "atlantis_state" {
  for_each   = data.kubectl_file_documents.atlantis_state.manifests
  yaml_body  = each.value
  depends_on = [kubernetes_namespace.this]
}
