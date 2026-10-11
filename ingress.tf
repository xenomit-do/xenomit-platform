# Host names for the web UIs, served by Traefik (built into k3s).
#
# The k3d load balancer publishes ports 80 and 443 on the host (ops/k3d/cluster.yaml) and
# Traefik routes by Host header, so the UIs open on http://<name>.<base_domain>/ without
# a port. The names point at 127.0.0.1 through the Windows hosts file; ops/bootstrap.ps1
# adds any that are missing, from the `hostnames` output below.
#
# Add a UI by adding a line to local.ingress_hosts. The ingress must live in the namespace
# of its Service.

variable "base_domain" {
  description = "Domain of the local UI host names."
  type        = string
  default     = "xenomit.com"
}

locals {
  # name => where it is served from
  ingress_hosts = {
    argocd      = { namespace = "argocd", service = "argocd-server", port = 80 }
    gitea       = { namespace = "git", service = "gitea", port = 3000 }
    atlantis    = { namespace = "ci", service = "atlantis", port = 4141 }
    openobserve = { namespace = "observability", service = "openobserve", port = 5080 }
    panel       = { namespace = "xenomit-system", service = "web-panel", port = 3000 }
  }
}

resource "kubernetes_ingress_v1" "ui" {
  for_each = local.ingress_hosts

  metadata {
    name      = each.key
    namespace = each.value.namespace
    labels = {
      "app.kubernetes.io/part-of" = "xenomit"
    }
  }

  spec {
    ingress_class_name = "traefik"

    rule {
      host = "${each.key}.${var.base_domain}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = each.value.service
              port {
                number = each.value.port
              }
            }
          }
        }
      }
    }
  }

  # observability and xenomit-system are created by this stack
  depends_on = [kubectl_manifest.namespaces]
}

# Read by ops/bootstrap.ps1 to put the names in the hosts file.
output "hostnames" {
  value = sort([for name in keys(local.ingress_hosts) : "${name}.${var.base_domain}"])
}
