data "kubectl_path_documents" "namespaces" {
  pattern          = "${path.module}/manifests/namespaces/*.yaml"
  disable_template = true
}

resource "kubectl_manifest" "namespaces" {
  for_each          = data.kubectl_path_documents.namespaces.manifests
  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true
  wait_for_rollout  = false
}

resource "random_password" "postgres" {
  length  = 32
  special = false
}

resource "kubernetes_secret" "postgres_auth" {
  depends_on = [kubectl_manifest.namespaces]
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
  depends_on = [kubectl_manifest.namespaces]
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
  pattern          = "${path.module}/manifests/platform/*.yaml"
  disable_template = true
}

resource "kubectl_manifest" "platform" {
  depends_on        = [kubernetes_secret.postgres_auth, kubernetes_secret.openobserve_auth]
  for_each          = data.kubectl_path_documents.platform.manifests
  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true
  wait_for_rollout  = false
}

data "kubectl_path_documents" "crds" {
  pattern          = "${path.module}/manifests/crds/*.yaml"
  disable_template = true
}

resource "kubectl_manifest" "crds" {
  for_each          = data.kubectl_path_documents.crds.manifests
  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true
  wait_for_rollout  = false
}
