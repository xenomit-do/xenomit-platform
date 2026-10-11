resource "random_password" "vault" {
  length  = 64
  special = false
}
resource "kubernetes_secret_v1" "vault_admin" {
  metadata {
    name      = "vault-admin"
    namespace = "xenomit-system"
  }
  data = { token = random_password.vault.result
  }
}
resource "helm_release" "vault" {
  name       = "vault"
  namespace  = "xenomit-system"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  version    = "0.30.0"
  values = [yamlencode({
    injector = { enabled = false }
    server = {
      dev       = { enabled = true, devRootToken = random_password.vault.result }
      resources = { requests = { cpu = "100m", memory = "128Mi" }, limits = { cpu = "500m", memory = "512Mi" } }
    }
  })]
  wait    = true
  timeout = 600
}
resource "kubernetes_network_policy_v1" "vault" {
  metadata {
    name      = "vault-local"
    namespace = "xenomit-system"
  }
  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "vault" }
    }
    policy_types = ["Ingress", "Egress"]
    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "xenomit-bots" }
        }
      }
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "observability" }
        }
      }
      from {
        pod_selector {
          match_labels = { "xenomit.io/component" = "gateway" }
        }
      }
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "ci" }
        }
      }
      ports {
        port     = "8200"
        protocol = "TCP"
      }
    }
    egress {}
  }
}
