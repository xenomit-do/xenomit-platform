<#
.SYNOPSIS
  Configure Vault's JWT auth method with the k3d cluster's ServiceAccount
  signing key (docs/09 S9.2a, ADR-23). Run AFTER the cluster exists.
.DESCRIPTION
  Vault lives outside the cluster and NEVER calls the Kubernetes API - instead
  the cluster's public SA signing key is installed statically into auth/jwt.
  Bot pods then log in with their projected SA token (audience "vault",
  sub "system:serviceaccount:<ns>:<sa>").

  Idempotent; re-run after a cluster rebuild to rotate to the new signing key
  (docs/09 S9.2a "the k3d bootstrap script reconfigures the mount").

  Uses the xenomit-ops token from ops/vault/cluster-keys.json (created by
  vault-init.ps1), or -VaultToken if given.
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
# NB: $PSScriptRoot is empty inside param() defaults when invoked via
# powershell.exe -File -- resolve paths in the body instead.
param(
  [string]$ClusterName = 'xenomit',
  [string]$VaultDir = '',
  [string]$VaultContainer = 'xenomit-vault',
  [string]$KeysFile = '',
  [string]$VaultToken = '',
  # k3s default issuer; verify with:
  #   kubectl create token <sa> --audience vault  -> iss claim
  [string]$BoundIssuer = 'https://kubernetes.default.svc.cluster.local',
  [string]$OrchestratorNamespace = 'xenomit-system',
  [string]$OrchestratorServiceAccount = 'orchestrator'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $VaultDir) { $VaultDir = $PSScriptRoot }
if (-not $KeysFile) { $KeysFile = Join-Path $VaultDir 'cluster-keys.json' }

function Write-Step([string]$Msg) { Write-Host "==> $Msg" -ForegroundColor Cyan }
function Write-Warn([string]$Msg) { Write-Host "!!  $Msg" -ForegroundColor Yellow }

# PS 5.1 turns stderr output of a native command into a terminating
# NativeCommandError under ErrorActionPreference=Stop. Every external call
# goes through this wrapper.
function Invoke-Native {
  param(
    [Parameter(Mandatory)][string]$Exe,
    [string[]]$NativeArgs = @(),
    [switch]$AllowFail
  )
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $Exe @NativeArgs 2>&1 | Out-String
    $rc = $LASTEXITCODE
  } finally { $ErrorActionPreference = $prev }
  if ($rc -ne 0 -and -not $AllowFail) { throw "$Exe $($NativeArgs -join ' ') failed (exit ${rc}):`n$out" }
  return ,@($rc, $out)
}

function Invoke-VaultCli {
  param([string[]]$VaultArgs, [switch]$AllowFail)
  $r = Invoke-Native docker (@('exec','-e',"VAULT_TOKEN=$script:Token",$VaultContainer,'vault') + $VaultArgs) -AllowFail
  if ($r[0] -ne 0 -and -not $AllowFail) {
    throw "vault $($VaultArgs -join ' ') failed (exit $($r[0])):`n$($r[1])"
  }
  return $r
}

function Test-VaultTokenLoaded {
  if ([string]::IsNullOrWhiteSpace($script:Token) -or $script:Token -eq '(revoked)') { return $false }
  $r = Invoke-VaultCli -VaultArgs @('token','lookup','-format=json') -AllowFail
  return ($r[0] -eq 0)
}

if ($WhatIfPreference) {
  Write-Step "WhatIf: would extract SA pubkey from k3d-$ClusterName-server-0, ensure auth/jwt,"
  Write-Step "        write auth/jwt/config (jwt_validation_pubkeys, bound_issuer=$BoundIssuer)"
  Write-Step "        and role 'orchestrator' (bound subject SA $OrchestratorServiceAccount in $OrchestratorNamespace)"
  return
}

# ------------------------------------------------------------ token ---------
if (-not $VaultToken) {
  if (-not (Test-Path $KeysFile)) { throw "No -VaultToken and $KeysFile not found (run vault-init.ps1 first)" }
  $keys = Get-Content $KeysFile -Raw | ConvertFrom-Json
  $VaultToken = if ($keys.ops_token) { $keys.ops_token } elseif ($keys.root_token -ne '(revoked)') { $keys.root_token } else { '' }
  if (-not $VaultToken) { throw 'No usable Vault token (root revoked, ops token missing)' }
}
$script:Token = $VaultToken
if (-not (Test-VaultTokenLoaded)) {
  Write-Warn 'Stored Vault token is invalid (often because root revoke cascaded to a non-orphan ops token). Re-running vault-init.ps1.'
  & (Join-Path $VaultDir 'vault-init.ps1')
  $keys = Get-Content $KeysFile -Raw | ConvertFrom-Json
  $script:Token = $keys.ops_token
  if (-not (Test-VaultTokenLoaded)) {
    throw 'No valid xenomit-ops token after vault-init.ps1 -- check ops/vault/cluster-keys.json'
  }
}

# --------------------------------------------------- SA signing pubkey ------
$server = "k3d-$ClusterName-server-0"
$saKeyInContainer = '/var/lib/rancher/k3s/server/tls/service.key'
$tmp = Join-Path $env:TEMP 'xenomit-sa.pub'
Write-Step "Extracting SA signing pubkey from $server"

# Preferred: openssl already inside the k3s server image -- no host dependency.
$r = Invoke-Native docker @('exec',$server,'sh','-c',"openssl pkey -in $saKeyInContainer -pubout") -AllowFail
$pubOk = ($r[0] -eq 0) -and ($r[1] -match 'BEGIN PUBLIC KEY')
if ($pubOk) { Set-Content -Encoding ascii -Path $tmp -Value $r[1] }
if (-not $pubOk) {
  # Fallback: copy the key out and use a host openssl (Git for Windows bundles one).
  $openssl = Get-Command openssl.exe -ErrorAction SilentlyContinue
  $exe = if ($openssl) { $openssl.Source } elseif (Test-Path "$env:ProgramFiles\Git\usr\bin\openssl.exe") { "$env:ProgramFiles\Git\usr\bin\openssl.exe" } else { $null }
  if (-not $exe) { throw 'Could not derive SA public key: no openssl in the k3s image and none on PATH. Install Git for Windows or openssl and retry.' }
  $saKey = Join-Path $env:TEMP 'xenomit-k3s-service.key'
  $null = Invoke-Native docker @('cp',"${server}:$saKeyInContainer",$saKey)
  $null = Invoke-Native $exe @('pkey','-in',$saKey,'-pubout','-out',$tmp)
  Remove-Item $saKey -ErrorAction SilentlyContinue
  $pubOk = (Test-Path $tmp) -and ((Get-Content $tmp -Raw) -match 'BEGIN PUBLIC KEY')
}
if (-not $pubOk) { throw 'Could not derive SA public key from the k3s service.key' }
Write-Step "SA pubkey -> $tmp"

# --------------------------------------------------------- jwt mount --------
$auth = (Invoke-VaultCli -VaultArgs @('auth','list','-format=json'))[1] | ConvertFrom-Json
$jwtEnabled = $null -ne $auth.PSObject.Properties['jwt/']
if (-not $jwtEnabled) {
  Write-Step 'Enabling auth/jwt'
  if ($PSCmdlet.ShouldProcess('auth/jwt', 'vault auth enable jwt')) {
    $null = Invoke-VaultCli -VaultArgs @('auth','enable','jwt')
  }
} else {
  Write-Step 'auth/jwt already enabled'
}

# -------------------------------------------------- jwt config (static) -----
Write-Step 'Installing cluster signing key into auth/jwt/config'
if ($PSCmdlet.ShouldProcess('auth/jwt/config', "jwt_validation_pubkeys + bound_issuer=$BoundIssuer")) {
  $null = Invoke-Native docker @('cp',$tmp,"${VaultContainer}:/tmp/sa.pub")
  $null = Invoke-VaultCli -VaultArgs @(
    'write','auth/jwt/config',
    'jwt_validation_pubkeys=@/tmp/sa.pub',
    "bound_issuer=$BoundIssuer")
}

# ------------------------------------------------- orchestrator role --------
$sub = "system:serviceaccount:${OrchestratorNamespace}:${OrchestratorServiceAccount}"
Write-Step "Writing jwt role 'orchestrator' (bound_subject=$sub)"
if ($PSCmdlet.ShouldProcess('auth/jwt/role/orchestrator', 'vault write role')) {
  $null = Invoke-VaultCli -VaultArgs @(
    'write','auth/jwt/role/orchestrator',
    'role_type=jwt',
    "bound_subject=$sub",
    'bound_audiences=vault',
    'user_claim=sub',
    'token_policies=xenomit-orchestrator',
    'token_ttl=15m',
    'token_max_ttl=1h')
}

Write-Step @'
Done.
  - Per-bot roles (bot-<id>, bound to SA bot-<id>, policy bot-<id>) are created
    by the operator at reconcile time via policy xenomit-orchestrator.
  - botd pods must project their SA token with audience "vault"
    (docs/02 S2.2 config vault.auth.jwt_role / token_file).
  - If the cluster is rebuilt, re-run this script: the new signing key replaces
    the old one here, and existing bot roles keep working.
'@
