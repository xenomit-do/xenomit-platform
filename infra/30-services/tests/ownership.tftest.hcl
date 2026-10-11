mock_provider "kubernetes" {}
mock_provider "random" {}
mock_provider "tls" {}
mock_provider "helm" {}
mock_provider "kubectl" {}
run "ownership" {
  command = plan
  variables {
    config = { enable_applications = false, deployment_revision = "main" }
  }
  assert {
    condition     = length(kubectl_manifest.applications) == 3
    error_message = "Default profile must deploy two runner pools and an empty desired fleet."
  }
  assert {
    condition     = alltrue([for r in local.projects.fleet.resources : r.group == "fleet.xenomit.io"])
    error_message = "Fleet Argo project may own only desired fleet CRs, never operator workload children."
  }
}
