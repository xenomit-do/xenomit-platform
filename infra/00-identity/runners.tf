resource "kubernetes_network_policy_v1" "runner_egress" {
  for_each = toset(["arc-build", "arc-platform"])
  metadata {
    name      = "runner-egress"
    namespace = each.key
  }
  spec {
    pod_selector {
      match_labels = { "xenomit.io/job-runner" = "true"
      }
    }
    policy_types = ["Egress"]
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system"
          }
        }
        pod_selector {
          match_labels = { "k8s-app" = "kube-dns"
          }
        }
      }
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }
    egress {
      to {
        ip_block {
          cidr   = "0.0.0.0/0"
          except = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "127.0.0.0/8"]
        }
      }
      ports {
        port     = "443"
        protocol = "TCP"
      }
      ports {
        port     = "80"
        protocol = "TCP"
      }
    }
  }
  depends_on = [kubernetes_namespace_v1.managed]
}
