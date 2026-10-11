# Cloudflare domain and webhook tunnel

Create a Cloudflare account. Add your existing domain under Websites, choose the appropriate plan,
and change its nameservers at your registrar to Cloudflare's assigned nameservers. Wait for the zone
to become Active. You do not need to transfer domain registration or forward router ports.

Copy the account and zone IDs. Create an API token with account Cloudflare Tunnel edit and zone DNS
edit access scoped to those IDs. Save it outside Git with mode 600; configure its path and your domain.
Avoid an existing atlantis.<domain> record owned by another service. The importer rejects duplicates.

OpenTofu creates a named remotely configured tunnel, its DNS record, and a route matching exactly
/events. Other routes receive 404. cloudflared opens an outbound connection from k3d; no public IP is
required. GitHub's webhook is https://atlantis.<domain>/events. Atlantis validates its shared secret.
Never add interactive Cloudflare Access authentication to /events: GitHub cannot log in.

Confirm cloudflared is Ready, the public root returns 404, and an unsigned POST /events is rejected.
Actual signed deliveries appear in GitHub webhook Recent deliveries. Cloudflare/DNS persists when
k3d is removed and is imported into new state on rebuild.

When adopting a tunnel created in the Cloudflare dashboard, set `existing_tunnel_id`
in your private bootstrap configuration to its UUID. Bootstrap verifies that tunnel
in the configured account and imports it even when its old name differs. OpenTofu
then owns its name, webhook-only ingress, connector token, and DNS record.
