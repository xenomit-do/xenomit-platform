# Credential rotation

External GitHub App keys, admin token and Cloudflare token are account prerequisites. Replace local
mode-600 credential files and run the reviewed identity apply from the host. Secret mounts update,
but environment variables require a rollout restart of Atlantis; ARC listeners must restart after
their auth Secrets change. Revoke old keys only after replacement registration succeeds.

Generated webhook secrets and passwords remain in OpenTofu state across repeated bootstrap. Rotate
them explicitly with a reviewed replacement plan, synchronize the repository webhook secret, and
restart consumers. A new cluster gets new local credentials; external GitHub/Cloudflare identities
remain. Bot/account credentials are supplied at runtime and can be lost, never committed to Git.
