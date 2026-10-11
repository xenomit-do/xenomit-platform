<#
.SYNOPSIS
  Bring up + initialize the local Vault container (docs/09 S9.2a, 11 S11.4 step 1).
.DESCRIPTION
  Idempotent. Steps:
    1. Generate a self-signed CA + server cert into ops/vault/tls (skipped if present)
    2. docker compose up -d
    3. vault operator init (if not initialized) -> unseal keys + root token into
       ops/vault/cluster-keys.json   *** keep this file off-box in real use ***
    4. Unseal (with the stored keys; re-runs just unseal again if needed)
    5. Enable secret/ KV v2; write orchestrator + ops policies
    6. Mint a scoped 'xenomit-ops' token (stored in cluster-keys.json)
    7. Revoke the root token unless -KeepRootToken
  Does NOT configure the Kubernetes JWT auth - that needs the cluster's SA
  signing key; see vault-configure-jwt.ps1 (run by bootstrap after k3d exists).
.NOTES
  Run on the Windows host with Docker Desktop running. -WhatIf is honored for
  every mutating call. Nothing is installed by this script.
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
# NB: $PSScriptRoot is empty inside param() defaults when invoked via
# powershell.exe -File -- resolve paths in the body instead.
param(
  [string]$VaultDir = '',
  [string]$ContainerName = 'xenomit-vault',
  [string]$ComposeFile = '',
  [string]$KeysFile = '',
  [int]$KeyShares = 5,
  [int]$KeyThreshold = 3,
  [switch]$KeepRootToken,
  [string]$VaultImage = 'hashicorp/vault:1.20'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $VaultDir)    { $VaultDir    = $PSScriptRoot }
if (-not $ComposeFile) { $ComposeFile = Join-Path $VaultDir 'docker-compose.yml' }
if (-not $KeysFile)    { $KeysFile    = Join-Path $VaultDir 'cluster-keys.json' }
$TlsDir = Join-Path $VaultDir 'tls'

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

function Find-OpenSsl {
  # Git for Windows ships a working openssl + openssl.cnf. Strawberry/cygwin builds
  # often appear first on PATH but point OPENSSL_CONF at a portable-drive path
  # that does not exist on this machine.
  foreach ($p in @("$env:ProgramFiles\Git\usr\bin\openssl.exe",
                   "${env:ProgramFiles(x86)}\Git\usr\bin\openssl.exe")) {
    if ($p -and (Test-Path -LiteralPath $p)) { return $p }
  }
  $cmd = Get-Command openssl.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Resolve-OpenSslConf([string]$Exe) {
  if ($env:OPENSSL_CONF -and (Test-Path -LiteralPath $env:OPENSSL_CONF)) {
    return $env:OPENSSL_CONF
  }
  $bin = Split-Path -Parent $Exe
  foreach ($rel in @('..\ssl\openssl.cnf', '..\..\etc\ssl\openssl.cnf', '..\..\ssl\openssl.cnf')) {
    $candidate = Join-Path $bin $rel
    if (Test-Path -LiteralPath $candidate) {
      return (Resolve-Path -LiteralPath $candidate).ProviderPath
    }
  }
  foreach ($p in @("$env:ProgramFiles\Git\usr\ssl\openssl.cnf",
                   "$env:ProgramFiles\Git\mingw64\etc\ssl\openssl.cnf")) {
    if (Test-Path -LiteralPath $p) { return $p }
  }
  return $null
}

# Run an openssl command either on the host or inside a throwaway container of
# the vault image (alpine base ships openssl); never installs anything.
function Invoke-OpenSsl([string[]]$OsslArgs) {
  $exe = Find-OpenSsl
  if ($exe) {
    $conf = Resolve-OpenSslConf $exe
    $prevConf = $env:OPENSSL_CONF
    try {
      if ($conf) { $env:OPENSSL_CONF = $conf }
      $null = Invoke-Native $exe $OsslArgs
    } finally {
      $env:OPENSSL_CONF = $prevConf
    }
    return
  }
  # Container fallback: mount tls dir, relative paths in $OsslArgs stay inside.
  $mount = "${TlsDir}:/tls"
  $r = Invoke-Native docker @('run','-d','-v',$mount,'-w','/tls','--entrypoint','sh',$VaultImage,'-c','sleep 30')
  $cid = $r[1].Trim()
  if (-not $cid) { throw 'No openssl on PATH and could not start a container for it' }
  try {
    $null = Invoke-Native docker (@('exec',$cid,'openssl') + $OsslArgs)
  } finally {
    $null = Invoke-Native docker @('rm','-f',$cid) -AllowFail
  }
}

function Invoke-VaultCli {
  param([string[]]$VaultArgs, [string]$Token = '', [switch]$AllowFail)
  $envArgs = @()
  if ($Token) { $envArgs += @('-e', "VAULT_TOKEN=$Token") }
  $r = Invoke-Native docker (@('exec') + $envArgs + @($ContainerName,'vault') + $VaultArgs) -AllowFail
  if ($r[0] -ne 0 -and -not $AllowFail) {
    throw "vault $($VaultArgs -join ' ') failed (exit $($r[0])):`n$($r[1])"
  }
  return $r
}

function Get-VaultStatus {
  $r = Invoke-VaultCli -VaultArgs @('status', '-format=json') -AllowFail
  # exit 0 = unsealed; 2 = sealed. Parse either way.
  try { return ($r[1] | ConvertFrom-Json) } catch { return $null }
}

function Test-VaultToken([string]$Token) {
  if ([string]::IsNullOrWhiteSpace($Token)) { return $false }
  if ($Token -eq '(revoked)') { return $false }
  $r = Invoke-VaultCli -VaultArgs @('token','lookup','-format=json') -Token $Token -AllowFail
  return ($r[0] -eq 0)
}

function Invoke-VaultGenerateRoot {
  param(
    [Parameter(Mandatory)][string[]]$UnsealKeysB64,
    [Parameter(Mandatory)][int]$Threshold
  )
  $null = Invoke-VaultCli -VaultArgs @('operator','generate-root','-cancel') -AllowFail
  $r = Invoke-VaultCli -VaultArgs @('operator','generate-root','-init','-format=json')
  $state = $r[1] | ConvertFrom-Json
  $nonce = $state.nonce
  $otp = $state.otp
  for ($i = 0; $i -lt $Threshold; $i++) {
    $r = Invoke-VaultCli -VaultArgs @(
      'operator','generate-root',"-nonce=$nonce",'-format=json',$UnsealKeysB64[$i]
    )
    $state = $r[1] | ConvertFrom-Json
    if ($state.complete) { break }
  }
  if (-not $state.complete -or [string]::IsNullOrWhiteSpace($state.encoded_root_token)) {
    throw 'vault operator generate-root did not complete'
  }
  $r = Invoke-VaultCli -VaultArgs @(
    'operator','generate-root','-decode',$state.encoded_root_token,"-otp=$otp",'-format=json'
  )
  return ($r[1] | ConvertFrom-Json).token
}

function Resolve-VaultAdminToken {
  param(
    [Parameter(Mandatory)]$Keys,
    [Parameter(Mandatory)][int]$Threshold,
    [Parameter(Mandatory)][string]$KeysFilePath
  )
  foreach ($tok in @($Keys.ops_token, $Keys.root_token)) {
    if (Test-VaultToken $tok) { return $tok }
  }
  Write-Warn 'cluster-keys.json tokens are invalid for this Vault (common after raft data was reset). Recovering via operator generate-root.'
  if (-not $PSCmdlet.ShouldProcess($ContainerName, 'vault operator generate-root')) {
    throw 'No valid Vault token and -WhatIf is set; cannot continue mount/policy setup'
  }
  $root = Invoke-VaultGenerateRoot -UnsealKeysB64 $Keys.unseal_keys_b64 -Threshold $Threshold
  $Keys.root_token = $root
  $Keys.ops_token = ''
  $Keys | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 $KeysFilePath
  return $root
}

function Test-VaultServerCertHasSan([string]$CrtPath) {
  $exe = Find-OpenSsl
  if (-not $exe) { return $true }
  $r = Invoke-Native -Exe $exe -NativeArgs @('x509','-in',$CrtPath,'-ext','subjectAltName','-noout') -AllowFail
  return ($r[0] -eq 0 -and $r[1] -match 'DNS:|IP Address:')
}

# ---------------------------------------------------------------- 1. TLS ----
$svCrt = Join-Path $TlsDir 'vault.crt'
$svKey = Join-Path $TlsDir 'vault.key'
$ext   = 'subjectAltName=DNS:localhost,DNS:vault,DNS:xenomit-vault,DNS:host.k3d.internal,' +
         'DNS:vault.xenomit-system.svc.cluster.local,IP:127.0.0.1'

function New-VaultServerCert {
  Invoke-OpenSsl @('req','-newkey','rsa:2048','-nodes',
                   '-keyout','vault.key','-out','vault.csr','-subj','/CN=vault',
                   '-addext',$ext)
  # Copy CSR extensions (SANs) into the signed cert; without this, only CN=vault is issued
  # and https://127.0.0.1:8200 fails TLS verification (healthcheck + VAULT_ADDR).
  Invoke-OpenSsl @('x509','-req','-in','vault.csr','-CA','ca.crt','-CAkey','ca.key',
                   '-CAcreateserial','-days','3650','-sha256','-out','vault.crt',
                   '-copy_extensions','copy')
  Remove-Item vault.csr -ErrorAction SilentlyContinue
}

$skipTls = (Test-Path $svCrt) -and (Test-VaultServerCertHasSan $svCrt)
if ($skipTls) {
  Write-Step "TLS certs already present in $TlsDir -- skipping generation"
} elseif ((Test-Path $svCrt) -and -not (Test-VaultServerCertHasSan $svCrt)) {
  Write-Warn "vault.crt has no subjectAltName -- regenerating server cert (CA unchanged)"
  if ($PSCmdlet.ShouldProcess($TlsDir, 'regenerate Vault server TLS cert')) {
    $null = New-Item -ItemType Directory -Force -Path $TlsDir
    Push-Location $TlsDir
    try {
      Remove-Item $svCrt, $svKey -Force -ErrorAction SilentlyContinue
      New-VaultServerCert
    } finally { Pop-Location }
  }
} else {
  Write-Step "Generating self-signed CA + server cert into $TlsDir"
  $null = New-Item -ItemType Directory -Force -Path $TlsDir
  if ($PSCmdlet.ShouldProcess($TlsDir, 'generate Vault TLS materials')) {
    Push-Location $TlsDir
    try {
      Invoke-OpenSsl @('req','-x509','-newkey','rsa:2048','-sha256','-days','3650','-nodes',
                       '-keyout','ca.key','-out','ca.crt','-subj','/CN=xenomit-vault-ca',
                       '-addext','basicConstraints=critical,CA:TRUE')
      New-VaultServerCert
    } finally { Pop-Location }
  }
}

# -------------------------------------------------------------- 2. up -------
if ($PSCmdlet.ShouldProcess($ComposeFile, 'docker compose up -d')) {
  Write-Step "Starting Vault container ($ContainerName)"
  $null = Invoke-Native docker @('compose','-f',$ComposeFile,'up','-d')
}

# Wait for the API to answer (501 not-init / 503 sealed / 200 ok / 429 standby).
$ready = $false
$tries = if ($WhatIfPreference) { 1 } else { 60 }
for ($i = 0; $i -lt $tries; $i++) {
  $st = Get-VaultStatus
  if ($null -ne $st) { $ready = $true; break }
  Start-Sleep -Seconds 2
}
if (-not $ready) {
  if ($WhatIfPreference) { Write-Warn 'Vault API not reachable (expected under -WhatIf/DryRun) -- stopping here'; return }
  throw "Vault API did not respond inside $ContainerName within 120s"
}

# --------------------------------------------------------- 3. init/unseal ---
$keys = $null
if (Test-Path $KeysFile) { $keys = Get-Content $KeysFile -Raw | ConvertFrom-Json }

$st = Get-VaultStatus
if (-not $st.initialized) {
  Write-Step "vault operator init (shares=$KeyShares threshold=$KeyThreshold)"
  if ($PSCmdlet.ShouldProcess($ContainerName, 'vault operator init')) {
    $r = Invoke-VaultCli -VaultArgs @('operator','init','-format=json',
                                      "-key-shares=$KeyShares","-key-threshold=$KeyThreshold")
    $init = $r[1] | ConvertFrom-Json
    [pscustomobject]@{
      unseal_keys_b64 = $init.unseal_keys_b64
      root_token      = $init.root_token
      ops_token       = ''
      created_at      = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 $KeysFile
    Write-Warn "Unseal keys + root token written to $KeysFile -- move them off-box; they are the keys to every user's credentials."
  }
  $keys = if (Test-Path $KeysFile) { Get-Content $KeysFile -Raw | ConvertFrom-Json } else { $null }
  if (-not $keys) {
    Write-Warn 'No keys materialized (WhatIf path) -- skipping unseal/mount/policy steps'
    return
  }
} elseif (-not $keys -or -not $keys.unseal_keys_b64) {
  throw "Vault is already initialized but $KeysFile is missing/has no unseal keys. Unseal manually or recover the keys before continuing."
}

$st = Get-VaultStatus
if ($st.sealed) {
  Write-Step 'Unsealing Vault'
  if ($PSCmdlet.ShouldProcess($ContainerName, "vault operator unseal x$KeyThreshold")) {
    for ($i = 0; $i -lt $KeyThreshold; $i++) {
      $null = Invoke-VaultCli -VaultArgs @('operator','unseal', $keys.unseal_keys_b64[$i])
    }
  }
}
$st = Get-VaultStatus
if ($st.sealed) { throw 'Vault still sealed after unseal attempt' }
Write-Step 'Vault unsealed'

$adminToken = Resolve-VaultAdminToken -Keys $keys -Threshold $KeyThreshold -KeysFilePath $KeysFile

# ------------------------------------------------- 4. mounts + policies -----
$secrets = (Invoke-VaultCli -VaultArgs @('secrets','list','-format=json') -Token $adminToken)[1] | ConvertFrom-Json
# Set-StrictMode: missing JSON keys are not properties — do not use $secrets.'secret/' directly.
$secretMounted = $null -ne $secrets.PSObject.Properties['secret/']
if (-not $secretMounted) {
  Write-Step 'Enabling KV v2 at secret/'
  if ($PSCmdlet.ShouldProcess('secret/', 'vault secrets enable -version=2 kv')) {
    $null = Invoke-VaultCli -VaultArgs @('secrets','enable','-path=secret','-version=2','kv') -Token $adminToken
  }
} else {
  Write-Step 'secret/ already mounted'
}

foreach ($p in @('orchestrator','ops')) {
  $src = Join-Path $VaultDir "policies\$p.hcl"
  Write-Step "Writing policy xenomit-$p"
  if ($PSCmdlet.ShouldProcess("policy xenomit-$p", 'vault policy write')) {
    $tmp = "/tmp/xenomit-$p.hcl"
    $null = Invoke-Native docker @('cp',$src,"${ContainerName}:$tmp")
    $null = Invoke-VaultCli -VaultArgs @('policy','write',"xenomit-$p",$tmp) -Token $adminToken
  }
}

# ------------------------------------------------------ 5. ops token --------
if ((-not (Test-VaultToken $keys.ops_token)) -and $PSCmdlet.ShouldProcess('xenomit-ops token', 'vault token create')) {
  Write-Step 'Minting scoped xenomit-ops token'
  # Orphan so revoking the root token below does not cascade-revoke this token.
  $r = Invoke-VaultCli -VaultArgs @('token','create','-orphan','-policy=xenomit-ops',
                                    '-period=720h','-format=json') -Token $adminToken
  $tok = ($r[1] | ConvertFrom-Json).auth.client_token
  $keys.ops_token = $tok
  $keys | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 $KeysFile
}

# -------------------------------------------------- 6. revoke root ----------
if ($KeepRootToken) {
  Write-Warn 'Keeping root token (per -KeepRootToken). It is in cluster-keys.json -- treat it accordingly.'
} else {
  Write-Step 'Revoking root token (docs/09 S9.2a)'
  if ((Test-VaultToken $keys.root_token) -and $PSCmdlet.ShouldProcess('root token', 'vault token revoke')) {
    $null = Invoke-VaultCli -VaultArgs @('token','revoke', $keys.root_token) -Token $keys.root_token
    $keys.root_token = '(revoked)'
    $keys | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 $KeysFile
  }
  if (-not (Test-VaultToken $keys.ops_token)) {
    throw 'xenomit-ops token is not valid after root revoke (expected an orphan token)'
  }
}

Write-Step 'vault-init done. Next: bootstrap configures the JWT auth once the k3d cluster exists.'
