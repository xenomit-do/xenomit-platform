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
  catalog = jsondecode(file("${path.module}/../../repositories.json"))
  org     = local.catalog.organization
  repos   = local.catalog.repositories
}
resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "9.5.15"
  values     = [file("${path.module}/values/argocd.yaml")]
  wait       = true
  timeout    = 600
}
resource "helm_release" "arc" {
  name      = "arc"
  namespace = "arc-system"
  chart     = "oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller"
  version   = "0.13.1"
  values    = [yamlencode({ resources = { requests = { cpu = "100m", memory = "128Mi" }, limits = { cpu = "1", memory = "512Mi" } } })]
  wait      = true
  timeout   = 600
}
resource "kubernetes_service_account_v1" "atlantis" {
  metadata {
    name      = "atlantis"
    namespace = "ci"
  }
}
# Atlantis executes administrator-reviewed platform plans. Ordinary Actions runners have no such grants.
resource "kubernetes_cluster_role_binding_v1" "atlantis" {
  metadata {
    name = "xenomit-atlantis"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "atlantis"
    namespace = "ci"
  }
}
resource "kubernetes_config_map_v1" "atlantis" {
  metadata {
    name      = "atlantis-config"
    namespace = "ci"
  }
  data = {
    "repos.json" = jsonencode({
      repos = [for name, repo in local.repos : {
        id                            = "github.com/${local.org}/${name}"
        apply_requirements            = ["mergeable", "undiverged"]
        import_requirements           = ["mergeable", "undiverged"]
        allowed_overrides             = []
        allowed_workflows             = ["platform"]
        allow_custom_workflows        = false
        workflow                      = "platform"
        delete_source_branch_on_merge = true
        repo_locks = { mode = "on_plan"
        }
      } if repo.atlantis && !repo.archived]
      workflows = {
        platform = {
          plan = { steps = [
            { run = "cp /run/platform/config.json $PWD/runtime.auto.tfvars.json" },
            { init = { extra_args = ["-backend-config=in_cluster_config=true"] } },
            { plan = { extra_args = ["-lock-timeout=5m"]
              }
            }
            ]
          }
          apply = { steps = [{ apply = { extra_args = ["-lock-timeout=5m"] } }]
          }
        }
      }
    })
  }
}

data "kubectl_file_documents" "controllers" {
  for_each = toset(["atlantis", "cloudflared"])
  content = templatefile("${path.module}/manifests/${each.key}.yaml", {
    atlantis_url   = "https://atlantis.${var.config.domain}"
    repo_allowlist = join(",", [for name, repo in local.repos : "github.com/${local.org}/${name}" if repo.atlantis && !repo.archived])
    team_allowlist = "${var.config.maintainer_team}:plan,${var.config.maintainer_team}:apply,${var.config.maintainer_team}:unlock,${var.config.maintainer_team}:import"
  })
}
resource "kubectl_manifest" "controller_objects" {
  for_each   = merge([for name, docs in data.kubectl_file_documents.controllers : docs.manifests]...)
  yaml_body  = each.value
  depends_on = [kubernetes_service_account_v1.atlantis, kubernetes_cluster_role_binding_v1.atlantis, kubernetes_config_map_v1.atlantis]
}
