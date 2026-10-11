resource "random_password" "postgres" {
  length  = 32
  special = false
}

resource "kubernetes_secret" "postgres_auth" {
  metadata {
    name      = "postgres-auth"
    namespace = "xenomit-data"
  }
  type = "Opaque"
  data = {
    POSTGRES_USER     = "xenomit"
    POSTGRES_PASSWORD = random_password.postgres.result
  }
}

resource "random_password" "openobserve" {
  length           = 32
  special          = true
  override_special = "!@#%^*-_"
  min_lower        = 1
  min_upper        = 1
  min_numeric      = 1
  min_special      = 1
}

resource "kubernetes_secret" "openobserve_auth" {
  metadata {
    name      = "openobserve-auth"
    namespace = "observability"
  }
  type = "Opaque"
  data = {
    email         = "admin@xenomit.local"
    password      = random_password.openobserve.result
    authorization = "Basic ${base64encode("admin@xenomit.local:${random_password.openobserve.result}")}"
  }
}

data "kubectl_path_documents" "platform" {
  pattern          = "${local.source_root}/manifests/platform/*.yaml"
  disable_template = true
}

resource "kubectl_manifest" "platform" {
  depends_on = [kubernetes_secret.postgres_auth, kubernetes_secret.openobserve_auth]
  for_each = { for key, body in data.kubectl_path_documents.platform.manifests : key => body if !strcontains(body, "name: vault") && !strcontains(key, "otel-")
  }
  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true
  wait_for_rollout  = false
}

data "kubectl_path_documents" "crds" {
  pattern          = "${local.source_root}/manifests/crds/*.yaml"
  disable_template = true
}

resource "kubectl_manifest" "crds" {
  for_each          = data.kubectl_path_documents.crds.manifests
  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true
  wait_for_rollout  = false
}

data "kubectl_path_documents" "collector" {
  pattern          = "${path.module}/manifests/*.yaml"
  disable_template = true
}
resource "kubectl_manifest" "collector" {
  depends_on        = [kubernetes_secret.openobserve_auth]
  for_each          = data.kubectl_path_documents.collector.manifests
  yaml_body         = each.value
  server_side_apply = true
}
