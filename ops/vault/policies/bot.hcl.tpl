# Per-bot Vault policy template (docs/09 §9.2a, ADR-23). The operator renders
# {{BOT_ID}} to the XenomitBot name and writes it as policy "bot-<id>"; a JWT
# role of the same name binds it to the bot's ServiceAccount
# (system:serviceaccount:xenomit-bots:bot-<id>, audience "vault").
#
# A bot may READ its own subtree and nothing else: account credentials, proxy
# override, control token, instance token — all live under
# secret/data/bots/<id>/* (docs/02 §2.2). It cannot enumerate the fleet, read
# pool proxy credentials, or write anything. On bot delete the operator
# destroys this policy, the role and the data path (docs/09 §9.2).
path "secret/data/bots/{{BOT_ID}}/*" {
  capabilities = ["read"]
}

path "secret/metadata/bots/{{BOT_ID}}/*" {
  capabilities = ["read", "list"]
}
