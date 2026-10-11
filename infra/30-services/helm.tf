resource "helm_release" "kyverno" {
  name             = "kyverno"
  namespace        = "kyverno"
  create_namespace = true
  repository       = "https://kyverno.github.io/kyverno"
  chart            = "kyverno"
  version          = "3.9.1"
  values           = [file("${local.source_root}/values/kyverno-values-local.yaml")]
  wait             = true
  timeout          = 600
}

data "kubectl_path_documents" "policies" {
  pattern          = "${path.module}/policies/*.yaml"
  disable_template = true
}

resource "kubectl_manifest" "policies" {
  depends_on        = [helm_release.kyverno]
  for_each          = data.kubectl_path_documents.policies.manifests
  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true
  wait_for_rollout  = false
}
