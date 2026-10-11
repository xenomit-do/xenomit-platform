# Linux/WSL bootstrap

Use a Linux-native workspace such as ~/src/xenomit. The environment needs Docker
access, Git, Python 3, jq, curl, openssl, flock, kubectl, k3d 5.8.3, and OpenTofu 1.12.6. Install tools
from their official releases; the script checks requirements and does not modify the host OS.

1. Follow domain.md and github-apps.md once to obtain external access.
2. Publish this implementation, including trusted reusable workflows, on xenomit-platform main before enabling the shared policy. Clone xenomit-platform. Copy config.example.json to ~/.config/xenomit/config.json.
3. Fill IDs/domain/billing email/maintainers and credential-file paths. chmod 600 credential files;
   chmod 700 ~/.config/xenomit. Keep everything outside Git.
4. Run bash scripts/inventory.sh ~/src/xenomit and complete migration/publication reviews.
5. Run bash bootstrap.sh --workspace ~/src/xenomit. It checks Docker, clones full history, creates
   k3d, claims environment ownership, initializes shared state, imports external objects and applies
   projects in infra/stacks.txt. API credentials stay out of arguments/logs.
6. Merge CI onboarding PRs after source-check succeeds. Verify Argo at http://127.0.0.1:8080.
   Its initial admin password is in argocd/argocd-initial-admin-secret. Atlantis UI stays local via
   kubectl -n ci port-forward svc/atlantis 4141:4141.

Bootstrap is resumable. It never overwrites dirty checkouts or rotates credentials simply because it
runs again. .xenomit contains sensitive runtime metadata; keep mode 700 and never commit it.
Revisions.json records source revisions and actual local checkout heads separately.

Application images are initially unavailable: enable_applications defaults to false. Promote real
digests and provision application/runtime credentials before enabling the control plane and panel.
The fleet starts empty. A healthy platform is not a claim that bots without credentials can run.
