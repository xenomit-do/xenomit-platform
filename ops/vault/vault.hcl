# Vault server config (docs/09 §9.2a): integrated Raft storage on a named
# volume, TLS on, NOT dev mode, runs beside the k3d cluster — not in it — so a
# cluster rebuild never touches credentials.
storage "raft" {
  path    = "/vault/data"
  node_id = "vault-1"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/vault/tls/vault.crt"
  tls_key_file  = "/vault/tls/vault.key"

  # Listener-scoped telemetry (not the top-level telemetry block).
  telemetry {
    unauthenticated_metrics_access = true
  }
}

# Advertised API/cluster addresses. Single node: no HA peer traffic.
api_addr     = "https://vault:8200"
cluster_addr = "https://vault:8201"

ui              = true 
disable_mlock   = false   # container gets IPC_LOCK in docker-compose.yml
log_level       = "info"

# Phase 9: prometheus metrics for the sealed-Vault alert (docs/09 §9.2a,
# ci/observability/alerts/signoz-alerts.json VaultSealed). The otel collector
# scrapes /v1/sys/metrics through the vault Service; metrics expose
# operational counters only (no secret values), so unauthenticated access is
# acceptable locally — the listener is ClusterIP-reachable anyway.
telemetry {
  prometheus_retention_time = "30s"
  disable_hostname          = true
}
