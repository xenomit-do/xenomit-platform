# Orchestrator's Vault policy (docs/09 §9.1, §9.2a). Key property from the
# threat model: it may WRITE bot credential values but never READ them back —
# create/update/delete on data paths, read only on metadata (for existence
# checks during reconcile).
path "secret/data/bots/*" {
  capabilities = ["create", "update", "delete"]
}

path "secret/metadata/bots/*" {
  capabilities = ["read", "list", "delete"]
}

# Pool proxy credentials (docs/05 §5.6). The operator reads these only to copy
# the assigned proxy's credentials into the bot's own path, keeping the bot
# policy single-subtree.
path "secret/data/proxies/*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "secret/metadata/proxies/*" {
  capabilities = ["read", "list", "delete"]
}

# Per-bot policy + JWT role lifecycle (bot.hcl.tpl rendered per bot).
path "sys/policies/acl/bot-*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "auth/jwt/role/bot-*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
