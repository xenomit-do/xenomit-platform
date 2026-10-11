# Scoped token for the bootstrap/ops scripts themselves, created by
# vault-init.ps1 before the root token is revoked. Lets bootstrap re-run
# idempotently (re-render policies, reconfigure JWT auth on cluster rebuild —
# docs/09 §9.2a "rotate the keys on cluster rebuild") without a root token.
path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "sys/mounts" {
  capabilities = ["read"]
}

path "sys/auth" {
  capabilities = ["read", "list"]
}

path "sys/auth/jwt" {
  capabilities = ["read", "update", "sudo"]
}

path "auth/jwt/config" {
  capabilities = ["read", "update"]
}

path "auth/jwt/role/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Seeding/admin work: ops scripts seed bot paths (e.g. verify.ps1's round-trip
# probe) and pool proxy credentials. Same write-not-read shape as the
# orchestrator on bot data — reading users' credentials back is not an ops need.
path "secret/data/bots/*" {
  capabilities = ["create", "update", "delete"]
}

path "secret/metadata/bots/*" {
  capabilities = ["read", "list", "delete"]
}

path "secret/data/proxies/*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "secret/metadata/proxies/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/data/infra/*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "secret/metadata/infra/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
