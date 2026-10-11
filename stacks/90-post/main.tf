# Stage 3: objects that need live cluster facts or secrets that must not be in git.
# Runs after the platform stack has created the workload namespaces.

locals {
  ops = "${path.module}/../../ops"

  # cluster-keys.json is written by PowerShell and starts with a UTF-8 BOM.
  vault_keys      = jsondecode(trimprefix(file("${local.ops}/vault/cluster-keys.json"), "﻿"))
  vault_ops_token = local.vault_keys.ops_token

  # Multi-document YAML -> one entry per document that has a `kind:` (this drops
  # the comment-only chunk in front of the first `---`).
  split_docs = {
    cidr_policies = [
      for d in split("\n---", replace(
        replace(replace(file("${local.ops}/k8s/12-node-cidr-policies.template.yaml"), "\r\n", "\n"), "__K3D_NODE_CIDR__", var.node_cidr),
      "__VAULT_HOST_IP__", var.vault_host_ip)) : d if length(regexall("(?m)^kind:", d)) > 0
    ]
    localhost_apps = [
      for d in split("\n---", replace(file("${local.ops}/k3d/localhost-apps.yaml"), "\r\n", "\n")) : d if length(regexall("(?m)^kind:", d)) > 0
    ]
  }
}

# ---- Vault CA for pods that talk to Vault --------------------------------------

resource "kubernetes_config_map" "vault_ca" {
  for_each = toset(["xenomit-system", "xenomit-bots", "observability"])
  metadata {
    name      = "vault-ca"
    namespace = each.key
  }
  data = {
    "ca.crt" = file("${local.ops}/vault/tls/ca.crt")
  }
}

# ---- Postgres / OpenObserve credentials --------------------------------------
# The platform stack generated these (random_password) and stored them as
# Secrets. Here they are re-shaped for the workloads and copied into Vault KV.

data "kubernetes_secret" "postgres" {
  metadata {
    name      = "postgres-auth"
    namespace = "xenomit-data"
  }
}

data "kubernetes_secret" "openobserve" {
  metadata {
    name      = "openobserve-auth"
    namespace = "observability"
  }
}

resource "kubernetes_secret" "postgres_dsn" {
  metadata {
    name      = "postgres-auth"
    namespace = "xenomit-system"
  }
  data = {
    "orchestrator-url" = "postgres://xenomit:${data.kubernetes_secret.postgres.data["POSTGRES_PASSWORD"]}@postgres.xenomit-data:5432/xenomit_orchestrator"
    "panel-url"        = "postgresql://xenomit:${data.kubernetes_secret.postgres.data["POSTGRES_PASSWORD"]}@postgres.xenomit-data:5432/xenomit_panel?schema=public"
  }
}

resource "vault_kv_secret_v2" "postgres" {
  mount = "secret"
  name  = "infra/postgres"
  data_json = jsonencode({
    user     = "xenomit"
    password = data.kubernetes_secret.postgres.data["POSTGRES_PASSWORD"]
  })
}

resource "vault_kv_secret_v2" "openobserve" {
  mount = "secret"
  name  = "infra/openobserve"
  data_json = jsonencode({
    email    = data.kubernetes_secret.openobserve.data["email"]
    password = data.kubernetes_secret.openobserve.data["password"]
  })
}

# ---- NetworkPolicies that need the real k3d subnet and the Vault host IP --------

resource "kubectl_manifest" "cidr_policies" {
  for_each  = { for i, d in local.split_docs.cidr_policies : tostring(i) => d }
  yaml_body = each.value
}

# ---- loopback ports for OpenObserve, the panel and Postgres ---------------------

resource "kubectl_manifest" "localhost_apps" {
  for_each  = { for i, d in local.split_docs.localhost_apps : tostring(i) => d }
  yaml_body = each.value
}
