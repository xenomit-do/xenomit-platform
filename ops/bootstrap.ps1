<#
.SYNOPSIS
  Bring up the local Xenomit platform on an empty machine, or bring it up to date.
.DESCRIPTION
  The script does three things and knows nothing about what the platform contains:

    1. Gets the machine ready: clones missing repositories from GitHub (ops/repos.txt),
       starts Vault, creates the k3d cluster.
    2. Applies the OpenTofu stacks listed in ops/stacks.txt, in that order. The first three
       (bootstrap/*) build the minimal working structure: Gitea, Argo CD, Atlantis. Every
       other stack is OpenTofu in git: the platform stacks Atlantis also runs, and the admin
       stacks in stacks/. Adding a change means editing those, never this script.
    3. Pushes the local checkouts to Gitea whenever a stack lists them in its
       `seed_repositories` output.

  Stacks are connected by name: every output of a stack becomes a variable of the later
  stacks that declare a variable with the same name. See ops/BOOTSTRAP-IAC.md.

  Run it from an elevated (administrator) PowerShell: the UIs are served on names such as
  argocd.xenomit.com, and the names that a stack lists in its `hostnames` output are added
  to the Windows hosts file when they are missing. Existing entries are never changed.
.PARAMETER NoCommit
  By default pending changes in a checkout are committed (secrets and state files are
  refused) before it is pushed, so Gitea matches what is applied. This only warns instead.
.PARAMETER Reset
  Delete the cluster, the Vault data volume and the local state first (from scratch).
.EXAMPLE
  .\bootstrap.ps1            # create or resume
  .\bootstrap.ps1 -Reset     # from scratch
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
  [switch]$Reset,
  [switch]$NoCommit,
  [string]$ClusterName = 'xenomit',
  [string]$GithubOrg = 'xenomit-do'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Ops        = $PSScriptRoot
$Repos      = Split-Path (Split-Path $Ops -Parent) -Parent        # folder that holds all xenomit-* checkouts
$Vault      = Join-Path $Ops 'vault'
$Org        = 'xenomit'
$KubeConfig = Join-Path $env:USERPROFILE '.kube\config'
$GiteaUrl   = 'http://127.0.0.1:3000'     # loopback ports come from ops/k3d/cluster.yaml
$ArgoServer = '127.0.0.1:8080'
$TokenFile  = Join-Path $Repos 'github pat.txt'   # GitHub token, optional; never in git

$Hostnames = @()   # collected from the `hostnames` outputs of the stacks

function Step([string]$Msg) { Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Hide([string]$Text) { $Text -replace 'Basic [A-Za-z0-9+/=]+', 'Basic ***' }

# Run a native program. Output is streamed; a non-zero exit code stops the script.
# (Windows PowerShell 5.1 treats stderr output as an error unless it is relaxed here.)
function Run([string]$Exe, [string[]]$Arguments) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { & $Exe @Arguments; $rc = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
  if ($rc -ne 0) { throw (Hide "$Exe $($Arguments -join ' ') failed (exit $rc)") }
}

# Same, but returns the output as text instead of printing it.
function Capture([string]$Exe, [string[]]$Arguments, [switch]$AllowFail) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $out = (& $Exe @Arguments 2>&1 | Out-String).Trim(); $rc = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
  if ($rc -ne 0 -and -not $AllowFail) { throw (Hide "$Exe $($Arguments -join ' ') failed (exit ${rc}):`n$out") }
  return $out
}

# True when `git <args>` exits 0 (used for yes/no questions such as --is-ancestor).
function GitOk([string[]]$Arguments) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $null = & git @Arguments 2>&1 } finally { $ErrorActionPreference = $prev }
  return ($LASTEXITCODE -eq 0)
}

function Read-List([string]$File) {
  Get-Content $File | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
}

# ---- repositories ----------------------------------------------------------------------

# Clone every repository of ops/repos.txt that is not next to this one yet.
function Clone-Missing {
  $auth = @()
  if (Test-Path $TokenFile) {
    $token = (Get-Content $TokenFile -Raw).Trim()
    $auth = @('-c', 'http.extraHeader=Authorization: Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$token")))
  }
  foreach ($name in Read-List (Join-Path $Ops 'repos.txt')) {
    if (Test-Path (Join-Path $Repos $name)) { continue }
    Write-Host "    cloning $name from GitHub"
    Run 'git' ($auth + @('-C', $Repos, 'clone', '-q', "https://github.com/$GithubOrg/$name.git", $name))
  }
}

# Connect a local checkout to its Gitea repository and bring the two in line:
#   * remote "gitea" -> the loopback URL, current branch tracks gitea/main (or gitea/<branch>)
#   * empty Gitea repo      -> push the real history to main (first bootstrap)
#   * Gitea main is ahead   -> fast-forward the local main (e.g. after a merged pull request)
#   * local main is ahead   -> main is protected, so push branch "bootstrap-sync" and ask
#                              for a pull request
# Credentials are passed per command and never stored in the checkout.
function Sync([string]$Name, [string]$Password) {
  $dir  = Join-Path $Repos $Name
  $url  = "$GiteaUrl/$Org/$Name.git"
  $auth = 'http.extraHeader=Authorization: Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("gitops:$Password"))
  $in   = @('-C', $dir)
  if (-not (Test-Path (Join-Path $dir '.git'))) { Write-Warning "$Name is not a git checkout, skipped"; return }

  if ((Capture 'git' ($in + 'remote')) -split '\s+' -contains 'gitea') { Run 'git' ($in + 'remote', 'set-url', 'gitea', $url) }
  else { Run 'git' ($in + 'remote', 'add', 'gitea', $url) }

  # symbolic-ref also works in a checkout that has no commit yet
  $branch = Capture 'git' ($in + 'symbolic-ref', '--short', 'HEAD') -AllowFail
  if (-not $branch -or $branch -match '^fatal') { Write-Warning "$Name is on a detached HEAD, skipped"; return }
  # Argo CD and Atlantis read what is in Gitea, so pending work has to be committed first.
  $dirty = [bool](Capture 'git' ($in + 'status', '--porcelain'))
  if ($dirty -and $NoCommit) {
    Write-Warning "$Name has uncommitted changes (-NoCommit). They will not be on Gitea."
  } elseif ($dirty) {
    Run 'git' ($in + 'add', '-A')
    $staged = Capture 'git' ($in + 'diff', '--cached', '--name-only')
    if ($staged -match '(?m)(\.terraform/|tfstate|\.key$|\.srl$|cluster-keys\.json)') {
      Run 'git' ($in + 'reset', '-q')
      throw "${Name}: refusing to commit secrets or state files:`n$staged"
    }
    $who = @()
    if (-not (Capture 'git' ($in + 'config', 'user.email') -AllowFail)) { $who = @('-c', 'user.name=xenomit-ops', '-c', 'user.email=ops@xenomit.local') }
    Run 'git' ($who + $in + 'commit', '-q', '-m', 'bootstrap: sync working tree')
    Write-Host "    ${Name}: committed pending changes on $branch"
    $dirty = $false
  }

  if (-not (GitOk ($in + 'rev-parse', '--verify', '-q', 'HEAD'))) { Write-Warning "$Name has no commits, skipped"; return }

  $remoteMain = Capture 'git' (@('-c', $auth) + $in + 'ls-remote', '--heads', 'gitea', 'main')
  if (-not $remoteMain) {
    Run 'git' (@('-c', $auth) + $in + 'push', '-q', '-u', 'gitea', 'HEAD:refs/heads/main')
    Write-Host "    $Name -> $Org/$Name main (new, tracking gitea/main)"
    return
  }

  Run 'git' (@('-c', $auth) + $in + 'fetch', '-q', 'gitea', 'main')
  if (-not (GitOk ($in + 'merge-base', 'HEAD', 'gitea/main'))) {
    Write-Warning "$Name shares no history with $Org/$Name on Gitea. Run bootstrap.ps1 -Reset to start from your history."
    return
  }
  if ($branch -ne 'main') {
    Run 'git' (@('-c', $auth) + $in + 'push', '-q', '-u', 'gitea', "HEAD:refs/heads/$branch")
    Write-Host "    $Name branch $branch -> gitea/$branch"
    return
  }
  Run 'git' ($in + 'branch', '--set-upstream-to=gitea/main', 'main')
  if (GitOk ($in + 'merge-base', '--is-ancestor', 'gitea/main', 'HEAD')) {
    if (GitOk ($in + 'merge-base', '--is-ancestor', 'HEAD', 'gitea/main')) { Write-Host "    $Name already in sync with gitea/main"; return }
    Run 'git' (@('-c', $auth) + $in + 'push', '-q', '-f', 'gitea', 'HEAD:refs/heads/bootstrap-sync')
    Write-Warning "$Name main is ahead of Gitea and protected. Pushed branch 'bootstrap-sync'; open a pull request from it."
  } elseif (GitOk ($in + 'merge-base', '--is-ancestor', 'HEAD', 'gitea/main')) {
    if ($dirty) { Write-Warning "$Name is behind gitea/main but has uncommitted changes, not fast-forwarded"; return }
    Run 'git' ($in + 'merge', '-q', '--ff-only', 'gitea/main')
    Write-Host "    $Name fast-forwarded to gitea/main"
  } else {
    Run 'git' (@('-c', $auth) + $in + 'push', '-q', '-f', 'gitea', 'HEAD:refs/heads/bootstrap-sync')
    Write-Warning "$Name and gitea/main have diverged. Pushed branch 'bootstrap-sync'; open a pull request and resolve it there."
  }
}

# ---- hosts file ------------------------------------------------------------------------

# Make every name resolve to this machine (127.0.0.1, where the k3d load balancer publishes
# ports 80 and 443). Only names that are missing are added; an existing entry is left alone,
# and a warning is printed when it points somewhere else.
function Ensure-Hosts([string[]]$Names) {
  if (-not $Names) { return }
  $file = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
  $known = @{}
  foreach ($line in Get-Content $file) {
    $fields = @(($line -replace '#.*', '').Trim() -split '\s+' | Where-Object { $_ })
    if ($fields.Count -ge 2) { foreach ($n in $fields[1..($fields.Count - 1)]) { $known[$n.ToLower()] = $fields[0] } }
  }
  $missing = @()
  foreach ($name in ($Names | Sort-Object -Unique)) {
    if (-not $known.ContainsKey($name.ToLower())) { $missing += $name }
    elseif ($known[$name.ToLower()] -ne '127.0.0.1') { Write-Warning "hosts: $name already points to $($known[$name.ToLower()]), not changed" }
  }
  if ($missing.Count -eq 0) { Write-Host '    hosts file already has every name'; return }
  $add = @('', '# Xenomit local platform (added by ops/bootstrap.ps1)') + @($missing | ForEach-Object { "127.0.0.1 $_" })
  Add-Content -Path $file -Value $add -Encoding ASCII
  Write-Host "    added to the hosts file: $($missing -join ', ')"
}

# ---- stacks ----------------------------------------------------------------------------

# Values the stacks can ask for, by variable name. Outputs of applied stacks are added.
$Ctx = @{
  kube_config_path = $KubeConfig
  kube_context     = "k3d-$ClusterName"
  gitea_url        = $GiteaUrl
  gitea_base_url   = $GiteaUrl
  argocd_server    = $ArgoServer
}
if (Test-Path $TokenFile) { $Ctx['github_token_file'] = $TokenFile }

# The platform stacks keep their state in a Secret inside the cluster so Atlantis can take
# over later. From the host we reach the same Secret through the kubeconfig instead of the
# pod's ServiceAccount.
$HostBackend = @('-backend-config=in_cluster_config=false',
                 "-backend-config=config_path=$KubeConfig",
                 "-backend-config=config_context=k3d-$ClusterName")

# init + apply one stack. Variables go in as TF_VAR_* (keeps secrets off the command line).
function Apply-Stack([string]$State, [string]$Rel) {
  $dir = Join-Path $Repos $Rel
  if (-not (Test-Path $dir)) { throw "stack $Rel not found in $Repos (is the repository cloned?)" }
  Step "Apply $Rel"

  # Hand over what the stack declares and the context knows.
  $declared = @(Get-ChildItem $dir -Filter '*.tf' | ForEach-Object {
    Select-String -Path $_.FullName -Pattern '^\s*variable\s+"([^"]+)"' | ForEach-Object { $_.Matches[0].Groups[1].Value } })
  $given = @()
  foreach ($name in $declared) {
    if ($Ctx.ContainsKey($name) -and "$($Ctx[$name])" -ne '') { Set-Item "Env:TF_VAR_$name" ([string]$Ctx[$name]); $given += $name }
  }
  try {
    $initArgs = @("-chdir=$dir", 'init', '-input=false', '-reconfigure')
    if ($State -eq 'cluster') { $initArgs += $HostBackend }
    Run 'tofu' $initArgs
    Run 'tofu' @("-chdir=$dir", 'apply', '-input=false', '-auto-approve')
  } finally {
    foreach ($name in $given) { Remove-Item "Env:TF_VAR_$name" -ErrorAction SilentlyContinue }
  }

  # Outputs become variables of the later stacks.
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $json = (& tofu "-chdir=$dir" output -json 2>$null | Out-String) } finally { $ErrorActionPreference = $prev }
  if (-not $json.Trim()) { return }
  $outputs = $json | ConvertFrom-Json
  foreach ($o in $outputs.PSObject.Properties) {
    $v = $o.Value.value
    $Ctx[$o.Name] = if ($v -is [string]) { $v } else { ConvertTo-Json -InputObject $v -Compress -Depth 6 }
  }

  # Names the stack serves; they go into the hosts file at the end.
  if ($outputs.PSObject.Properties['hostnames']) { $script:Hostnames += @($outputs.hostnames.value) }

  # A stack that creates repositories lists them here so their checkouts are pushed now.
  if ($outputs.PSObject.Properties['seed_repositories']) {
    Step "Push the checkouts of $Rel to Gitea"
    foreach ($repo in @($outputs.seed_repositories.value)) { Sync $repo $Ctx['gitops_password'] }
  }
}

# ---------------------------------------------------------------------------------------

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this script from an elevated PowerShell (Run as administrator): it edits the hosts file for the UI host names.' }

if ($Reset) {
  Step 'Reset: removing cluster, Vault data and local state'
  & (Join-Path $Ops 'teardown.ps1') -RemoveVaultData -Confirm:$false
}

foreach ($tool in 'docker', 'kubectl', 'k3d', 'tofu', 'git') {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool is required but not on PATH" }
}

Step 'Repositories'
Clone-Missing

Step 'Vault (Docker container beside the cluster)'
& (Join-Path $Vault 'vault-init.ps1')

Step 'k3d cluster'
if ((Capture 'k3d' @('cluster', 'list', '--no-headers') -AllowFail) -match "(?m)^$ClusterName\s") {
  Write-Host "    cluster $ClusterName already exists"
} else {
  Run 'k3d' @('cluster', 'create', '--config', (Join-Path $Ops 'k3d\cluster.yaml'), '--wait')
}
Run 'kubectl' @('config', 'use-context', "k3d-$ClusterName")
Run 'kubectl' @('wait', '--for=condition=Ready', 'nodes', '--all', '--timeout=180s')
& (Join-Path $Vault 'vault-configure-jwt.ps1') -ClusterName $ClusterName

# Facts about this cluster that stacks need (node-CIDR policies).
$Ctx['node_cidr'] = Capture 'docker' @('network', 'inspect', "k3d-$ClusterName", '--format', '{{range .IPAM.Config}}{{.Subnet}}{{end}}')
# k3d writes host.k3d.internal (the Docker host, where Vault runs) into every node's /etc/hosts.
$vaultIp = $null
try {
  $hosts = Capture 'docker' @('exec', "k3d-$ClusterName-server-0", 'cat', '/etc/hosts')
  if ($hosts -match '(?m)^(\d{1,3}(?:\.\d{1,3}){3})\s+.*\bhost\.k3d\.internal\b') { $vaultIp = $Matches[1] }
} catch { }
if (-not $vaultIp) { $vaultIp = Capture 'docker' @('network', 'inspect', "k3d-$ClusterName", '--format', '{{(index .IPAM.Config 0).Gateway}}') }
if ($vaultIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw "could not determine the Docker host IP (got '$vaultIp')" }
if ($Ctx['node_cidr'] -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d+$') { throw "could not determine the k3d network CIDR (got '$($Ctx['node_cidr'])')" }
$Ctx['vault_host_ip'] = $vaultIp

# A cluster built before the stacks layout has resources in the local state of bootstrap/3-tokens
# that now belong to other stacks (the GitHub token, the mirrors, the release secret). OpenTofu
# would try to refresh them with providers that stage no longer configures. Say so, plainly.
$oldState = Join-Path $Repos 'xenomit-platform\bootstrap\3-tokens\terraform.tfstate'
if ((Test-Path $oldState) -and ((Get-Content $oldState -Raw) -match '"type":\s*"(vault_kv_secret_v2|restapi_object|gitea_repository_actions_secret)"')) {
  throw "This cluster was built with the previous bootstrap layout and cannot be updated in place: its state still lists resources that moved to other stacks. Run .\bootstrap.ps1 -Reset (everything is rebuilt from the repositories)."
}

foreach ($line in Read-List (Join-Path $Ops 'stacks.txt')) {
  $state, $path = $line -split '\s+', 2
  if ($state -notin 'local', 'cluster') { throw "ops/stacks.txt: unknown state '$state' in '$line'" }
  Apply-Stack $state $path.Trim()
}

Step 'Hosts file'
Ensure-Hosts $Hostnames

Step 'Panel and API secrets'
& (Join-Path $Ops 'provision-panel-auth.ps1') -Namespace 'xenomit-system'
& (Join-Path $Ops 'provision-api-jwt.ps1') -Namespace 'xenomit-system'

Step 'Done'
Write-Host @'
The UIs (names from the `hostnames` output of the platform stack, ingress.tf):
  http://argocd.xenomit.com/        Argo CD
  http://gitea.xenomit.com/         Gitea
  http://openobserve.xenomit.com/   OpenObserve
  http://panel.xenomit.com/         Xenomit panel
  http://atlantis.xenomit.com/      Atlantis
Postgres:    127.0.0.1:5433
Direct loopback ports (used by this script): Argo CD 8080, Gitea 3000, OpenObserve 5080, panel 3002.
Passwords:   see ops/LOCAL-ACCESS.md. Later changes go through pull requests and Atlantis.
'@
