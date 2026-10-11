data "kubectl_file_documents" "operator_rbac" {
  content = file("${path.module}/../../services/gitops/base/operator-rbac.yaml")
}
resource "kubectl_manifest" "operator_rbac" {
  for_each  = data.kubectl_file_documents.operator_rbac.manifests
  yaml_body = each.value
}
