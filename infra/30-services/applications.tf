locals {
  deployment_repo = "https://github.com/xenomit-do/xenomit-deployments.git"
  applications = merge({
    "xenomit-build-runners" = { project = "runners", namespace = "arc-build", path = "runners/build", helm = true
    }
    "xenomit-platform-runners" = { project = "runners", namespace = "arc-platform", path = "runners/platform", helm = true
    }
    "xenomit-bots" = { project = "fleet", namespace = "xenomit-bots", path = "fleet", helm = false
    }
    }, var.config.enable_applications ? {
    "xenomit-control-plane" = { project = "services", namespace = "xenomit-system", path = "apps/control-plane", helm = false
    }
    "xenomit-panel" = { project = "services", namespace = "xenomit-system", path = "apps/panel", helm = false
    }
  } : {})
  projects = {
    runners = { namespaces = ["arc-build", "arc-platform"], resources = [{ group = "actions.github.com", kind = "AutoscalingRunnerSet" }, { group = "rbac.authorization.k8s.io", kind = "Role" }, { group = "rbac.authorization.k8s.io", kind = "RoleBinding" }, { group = "", kind = "ServiceAccount" }]
    }
    fleet = { namespaces = ["xenomit-bots"], resources = [{ group = "fleet.xenomit.io", kind = "XenomitBot" }, { group = "fleet.xenomit.io", kind = "BotRollout" }, { group = "fleet.xenomit.io", kind = "Proxy" }]
    }
    services = { namespaces = ["xenomit-system"], resources = [{ group = "", kind = "Service" }, { group = "", kind = "ServiceAccount" }, { group = "apps", kind = "Deployment" }, { group = "networking.k8s.io", kind = "NetworkPolicy" }, { group = "rbac.authorization.k8s.io", kind = "Role" }, { group = "rbac.authorization.k8s.io", kind = "RoleBinding" }]
    }
  }
}
resource "kubectl_manifest" "projects" {
  for_each = local.projects
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1", kind = "AppProject"
    metadata = { name = each.key, namespace = "argocd"
    }
    spec = {
      sourceRepos                = [local.deployment_repo]
      destinations               = [for ns in each.value.namespaces : { server = "https://kubernetes.default.svc", namespace = ns }]
      clusterResourceWhitelist   = []
      namespaceResourceWhitelist = each.value.resources
    }
  })
}
resource "kubectl_manifest" "applications" {
  for_each = local.applications
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1", kind = "Application"
    metadata = { name = each.key, namespace = "argocd"
    }
    spec = {
      project = each.value.project
      destination = { server = "https://kubernetes.default.svc", namespace = each.value.namespace
      }
      source = merge({ repoURL = local.deployment_repo, path = each.value.path, targetRevision = var.config.deployment_revision }, each.value.helm ? { helm = { releaseName = each.key } } : {})
      syncPolicy = {
        automated = { prune = true, selfHeal = true
        }
        syncOptions = ["FailOnSharedResource=true", "RespectIgnoreDifferences=true", "ServerSideApply=true"]
      }
      ignoreDifferences = [{ group = "fleet.xenomit.io", kind = "*", jsonPointers = ["/status", "/metadata/finalizers"] }]
    }
  })
  depends_on = [kubectl_manifest.projects, kubectl_manifest.crds]
}
