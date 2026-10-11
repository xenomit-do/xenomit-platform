locals {
  platform_repo = "${var.git_base}/xenomit/xenomit-platform.git"
  cluster_whitelist = [
    { group = "", kind = "Namespace" },
    { group = "apiextensions.k8s.io", kind = "CustomResourceDefinition" },
    { group = "rbac.authorization.k8s.io", kind = "*" },
    { group = "argoproj.io", kind = "AppProject" },
    { group = "kyverno.io", kind = "ClusterPolicy" },
    { group = "policies.kyverno.io", kind = "ImageValidatingPolicy" },
    { group = "kyverno.io", kind = "ClusterCleanupPolicy" },
    { group = "kyverno.io", kind = "PolicyException" },
    { group = "kyverno.io", kind = "UpdateRequest" },
    { group = "kyverno.io", kind = "EphemeralReport" },
    { group = "kyverno.io", kind = "ClusterEphemeralReport" },
    { group = "kyverno.io", kind = "GlobalContextEntry" },
    { group = "wgpolicyk8s.io", kind = "ClusterPolicyReport" },
    { group = "wgpolicyk8s.io", kind = "PolicyReport" },
  ]
  destinations = [
    "argocd", "xenomit-system", "xenomit-bots", "xenomit-data",
    "observability", "ci", "git", "kyverno",
  ]
}

resource "argocd_project" "platform" {
  metadata {
    name      = "xenomit"
    namespace = "argocd"
    labels = {
      "app.kubernetes.io/part-of" = "xenomit"
    }
  }
  spec {
    description = "Local platform infrastructure only. Fleet objects are operator-owned and excluded from GitOps sync."
    source_repos = [
      local.platform_repo,
    ]
    dynamic "destination" {
      for_each = local.destinations
      content {
        server    = var.cluster_server
        namespace = destination.value
      }
    }
    dynamic "cluster_resource_whitelist" {
      for_each = local.cluster_whitelist
      content {
        group = cluster_resource_whitelist.value.group
        kind  = cluster_resource_whitelist.value.kind
      }
    }
    namespace_resource_whitelist {
      group = "*"
      kind  = "*"
    }
    namespace_resource_blacklist {
      group = "fleet.xenomit.io"
      kind  = "*"
    }
    sync_window {
      kind         = "deny"
      schedule     = "* * * * *"
      duration     = "1h"
      applications = ["xenomit-bots"]
      manual_sync  = false
    }
    orphaned_resources {
      warn = true
      ignore {
        group = ""
        kind  = "ConfigMap"
        name  = "kube-root-ca.crt"
      }
      ignore {
        group = ""
        kind  = "ServiceAccount"
        name  = "default"
      }
    }
  }
}

resource "argocd_application" "control_plane" {
  depends_on = [argocd_project.platform]
  metadata {
    name      = "xenomit-control-plane"
    namespace = "argocd"
  }
  cascade = false
  wait    = false
  spec {
    project = argocd_project.platform.metadata[0].name
    destination {
      server    = var.cluster_server
      namespace = "xenomit-system"
    }
    source {
      repo_url        = local.platform_repo
      path            = "services/gitops/overlays/local"
      target_revision = "main"
    }
    revision_history_limit = 5
    sync_policy {
      automated {
        prune     = false
        self_heal = true
      }
      sync_options = ["CreateNamespace=false", "RespectIgnoreDifferences=true", "FailOnSharedResource=true", "ApplyOutOfSyncOnly=true"]
    }
  }
}

resource "argocd_application" "panel" {
  depends_on = [argocd_project.platform]
  metadata {
    name      = "xenomit-panel"
    namespace = "argocd"
  }
  cascade = false
  wait    = false
  spec {
    project = argocd_project.platform.metadata[0].name
    destination {
      server    = var.cluster_server
      namespace = "xenomit-system"
    }
    source {
      repo_url        = local.platform_repo
      path            = "services/gitops/panel"
      target_revision = "main"
    }
    revision_history_limit = 5
    sync_policy {
      automated {
        prune     = false
        self_heal = true
      }
      sync_options = ["CreateNamespace=false", "RespectIgnoreDifferences=true", "FailOnSharedResource=true", "ApplyOutOfSyncOnly=true"]
    }
  }
}

resource "argocd_application" "bots" {
  depends_on = [argocd_project.platform]
  metadata {
    name      = "xenomit-bots"
    namespace = "argocd"
  }
  cascade = false
  wait    = false
  spec {
    project = argocd_project.platform.metadata[0].name
    destination {
      server    = var.cluster_server
      namespace = "xenomit-bots"
    }
    source {
      repo_url        = local.platform_repo
      path            = "bots"
      target_revision = "main"
      directory {
        recurse = false
        exclude = ".gitkeep"
      }
    }
    revision_history_limit = 5
    sync_policy {
      sync_options = ["Prune=false", "Delete=false", "FailOnSharedResource=true"]
    }
  }
}
