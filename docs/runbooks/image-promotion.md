# Image builds and deployment PRs

The `images` workflow is dispatched from platform's protected main branch. It clones the catalog at recorded GitHub revisions, builds orchestrator, panel and botd on `xenomit-build`, publishes GHCR images with SBOM/provenance and keyless Cosign signatures from the protected main workflow, and passes only digest metadata to the platform promotion job. No Actions artifact uploads or hosted compute are used. BuildKit caches last only for the ephemeral runner; persistent local cache can be added without storing artifacts on GitHub.

Supply optional `deployment_token_file` in external bootstrap configuration: a mode-600 fine-grained token limited to xenomit-deployments with Contents and Pull requests write. OpenTofu places it only in platform-release, restricted to protected branches. Fork workflows cannot use it. Rotate it externally and reapply external infrastructure. The release job fails with a clear message if it is absent.

On first publication, make the three GHCR packages public (GitHub package administration), or supply a read credential using IaC before enabling applications. Repository visibility does not automatically make container packages public. Merge the digest PR after source-check passes, then set enable_applications=true and apply services. Fleet stays empty until desired Bot CRs and disposable runtime credentials are supplied. fleet/botd-image.json records the botd digest for reviewed desired-fleet changes; it is not a Kubernetes object.

All sibling sources and Flash build dependencies must be present in GitHub. Missing Dockerfiles, source directories or images fail the build instead of deploying mutable tags. Do not publish the proprietary Pepper plugin or secrets: mount runtime assets through the documented local credential setup.

Active admission policies require organization GHCR digest pins and the protected workflow signature. Third-party Vault is exempt from application pod policies and remains isolated by its network policy.
