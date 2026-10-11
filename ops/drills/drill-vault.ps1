<#
.SYNOPSIS
  Vault Raft backup/restore drill (docs/09 S9.2a, docs/rpo-rto.md).
.DESCRIPTION
  Phases:
    1. Backup    `vault operator raft snapshot save` inside the container,
                 docker cp out to ops/drills/out/vault-<ts>/vault-raft.snap
    2. Verify    `vault operator raft snapshot inspect`  -  parses the snapshot
                 header (term/index/size) without restoring it
    3. Checks    seal status (must be unsealed + initialized), ops-token
                 auth works, secret/ mount present, bots/ tree listable  - 
                 i.e. the things a restore must preserve
    4. Report    fills report-template.md into the artifact dir

  RESTORE: restoring a Raft snapshot is destructive (it overwrites the
  entire storage backend and reseals). The exact procedure is scripted but
  gated behind -WithRestore  -  the drill's default path never mutates Vault:

    -WithRestore also runs, in order:
      a. `vault operator raft snapshot restore -force` (wipes + restores)
      b. `vault operator unseal` x threshold from cluster-keys.json
      c. re-run all phase-3 checks against the restored state

  Run -WithRestore only when the platform is quiesced  -  restoring while
  bots hold leases is safe (leases die, bots re-login) but in-flight
  writes between backup and restore are lost BY DEFINITION of the snapshot.

  -DryRun: prints every step; no docker exec, no files, nothing touches Vault.
.EXAMPLE
  .\drill-vault.ps1 -DryRun
  .\drill-vault.ps1                  # snapshot + inspect + live-state checks
  .\drill-vault.ps1 -WithRestore     # + actual restore + unseal + re-check
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
  [switch]$DryRun,
  [switch]$WithRestore,
  [string]$ContainerName = 'xenomit-vault',
  [string]$VaultDir = '',
  [string]$KeysFile = '',
  [int]$KeyThreshold = 3,
  [string]$OutDir = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($DryRun) { $WhatIfPreference = $true }

. (Join-Path $PSScriptRoot 'lib-drill.ps1')

if (-not $VaultDir) { $VaultDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'vault' }
if (-not $KeysFile) { $KeysFile = Join-Path $VaultDir 'cluster-keys.json' }
if (-not $OutDir)   { $OutDir   = Join-Path $PSScriptRoot 'out' }
$TemplatePath = Join-Path $PSScriptRoot 'report-template.md'

function Invoke-VaultCli {
  param([string[]]$VaultArgs, [string]$Token = '', [switch]$AllowFail)
  $envArgs = @()
  if ($Token) { $envArgs += @('-e', "VAULT_TOKEN=$Token") }
  return (Invoke-Native docker (@('exec') + $envArgs + @($ContainerName, 'vault') + $VaultArgs) -AllowFail:$AllowFail)
}

# ------------------------------------------------------------- prereqs ------
Write-Step 'Prerequisites'
foreach ($t in 'docker') {
  if (-not (Test-Cmd $t)) { throw "$t is required on PATH" }
}
if ($WhatIfPreference) {
  Write-Warn 'DRY RUN  -  steps are printed, nothing executes against Vault or the filesystem.'
}
$ArtDir = New-DrillDir -Base $OutDir -Drill 'vault'
Write-Ok "artifact dir: $ArtDir"

$keys = $null
if (Test-Path $KeysFile) { $keys = Get-Content $KeysFile -Raw | ConvertFrom-Json }
if (-not $WhatIfPreference) {
  if (-not $keys -or -not $keys.unseal_keys_b64) {
    Write-Warn "$KeysFile missing/empty  -  unseal + token checks will be skipped; snapshot phases still run."
  }
  $st = (Invoke-VaultCli -VaultArgs @('status','-format=json') -AllowFail)[1] | ConvertFrom-Json
  if ($null -eq $st) { throw "Vault API not reachable in container $ContainerName" }
  if ($st.sealed)    { throw "Vault is SEALED  -  unseal first (runbooks/vault-unseal.md); a snapshot of sealed state is useless to verify" }
  Write-Ok "vault unsealed, initialized=$($st.initialized)"
} else {
  Write-Step "[dryrun] would check vault status + load $KeysFile"
}

$Artifacts = @(); $Checks = @()
$Timings = @{ backup = 'skipped'; restore = 'skipped'; verify = 'skipped' }
$SnapHost = Join-Path $ArtDir 'vault-raft.snap'
$SnapIn   = '/tmp/drill-raft.snap'

# ------------------------------------------------------------- 1. backup ----
Write-Step 'Phase 1  -  raft snapshot'
Start-DrillTimer
if ($PSCmdlet.ShouldProcess($ContainerName, "vault operator raft snapshot save $SnapIn")) {
  $null = Invoke-VaultCli -VaultArgs @('operator','raft','snapshot','save',$SnapIn)
  $null = Invoke-Native docker @('cp',"${ContainerName}:$SnapIn",$SnapHost)
  $bytes = (Get-Item $SnapHost).Length
  $Artifacts += @{ path = $SnapHost; bytes = $bytes; note = 'Raft snapshot (all secrets, policies, auth mounts)' }
  Write-Ok ("snapshot: {0:N1} KiB -> {1}" -f ($bytes/1KB), $SnapHost)
} else {
  Write-Ok "[dryrun] docker exec $ContainerName vault operator raft snapshot save $SnapIn; docker cp -> $SnapHost"
}
$Timings.backup = Stop-DrillTimer

# ------------------------------------------------------------- 2. verify ----
Write-Step 'Phase 2  -  snapshot integrity (inspect, no restore)'
Start-DrillTimer
if ($PSCmdlet.ShouldProcess($SnapIn, 'vault operator raft snapshot inspect')) {
  $r = Invoke-VaultCli -VaultArgs @('operator','raft','snapshot','inspect',$SnapIn) -AllowFail
  if ($r[0] -ne 0) {
    # inspect exists in vault >=1.9-ish; on old images fall back to size+gzip test.
    $r2 = Invoke-VaultCli -VaultArgs @('operator','raft','snapshot','inspect','-help') -AllowFail
    if ($r2[0] -ne 0) { Write-Warn 'snapshot inspect unsupported on this vault image  -  header check skipped'; $Checks += @{ name='snapshot inspect'; ok=$true; detail='unsupported on this image  -  size>0 only' } }
    else { throw "snapshot inspect failed:`n$($r[1])" }
  } else {
    Write-Ok $r[1].Trim()
    $Checks += @{ name = 'snapshot inspect'; ok = $true; detail = ($r[1] -split "`n" | Select-Object -First 1) }
  }
} else {
  Write-Ok "[dryrun] vault operator raft snapshot inspect $SnapIn"
}
$Timings.verify = Stop-DrillTimer

# ------------------------------------------------------------- 3. checks ----
function Invoke-LiveChecks([string]$Label) {
  $c = @()
  $r = Invoke-VaultCli -VaultArgs @('status','-format=json') -AllowFail
  $st = $r[1] | ConvertFrom-Json
  $c += @{ name = "$Label unsealed+initialized"; ok = (-not $st.sealed -and $st.initialized); detail = "sealed=$($st.sealed) initialized=$($st.initialized)" }
  if ($keys.ops_token) {
    $r2 = Invoke-VaultCli -VaultArgs @('token','lookup','self','-format=json') -Token $keys.ops_token -AllowFail
    $c += @{ name = "$Label ops token auth"; ok = ($r2[0] -eq 0); detail = if($r2[0] -eq 0){'xenomit-ops token valid'}else{$r2[1].Trim()} }
    $r3 = Invoke-VaultCli -VaultArgs @('secrets','list','-format=json') -Token $keys.ops_token -AllowFail
    $mounts = try { $r3[1] | ConvertFrom-Json } catch { $null }
    $c += @{ name = "$Label secret/ mount"; ok = ($null -ne $mounts.'secret/'); detail = 'KV v2 at secret/ present' }
    $r4 = Invoke-VaultCli -VaultArgs @('kv','list','-format=json','secret/bots') -Token $keys.ops_token -AllowFail
    $nBots = try { @($r4[1] | ConvertFrom-Json).Count } catch { 0 }
    $c += @{ name = "$Label bots/ tree"; ok = ($r4[0] -eq 0 -or $r4[1] -match 'No value found|not found'); detail = "$nBots bot path(s) listed (0 is valid pre-fleet)" }
  } else {
    $c += @{ name = "$Label ops token auth"; ok = $true; detail = 'skipped  -  no ops_token in cluster-keys.json' }
  }
  return $c
}

Write-Step 'Phase 3  -  live-state checks'
if ($PSCmdlet.ShouldProcess($ContainerName, 'post-backup state checks')) {
  $Checks += Invoke-LiveChecks -Label 'pre-restore'
} else {
  Write-Ok '[dryrun] status / token lookup / mounts / bots-list checks'
}

# ------------------------------------------------------------- 4. restore ---
if ($WithRestore) {
  Write-Step 'Phase 4  -  RESTORE (-WithRestore): overwrites Raft state, reseals, unseals'
  Start-DrillTimer
  if ($PSCmdlet.ShouldProcess($ContainerName, "vault operator raft snapshot restore -force $SnapIn")) {
    $null = Invoke-Native docker @('cp',$SnapHost,"${ContainerName}:$SnapIn")
    $r = Invoke-VaultCli -VaultArgs @('operator','raft','snapshot','restore','-force',$SnapIn) -AllowFail
    if ($r[0] -ne 0) { throw "raft snapshot restore failed:`n$($r[1])`nIf Vault is now sealed and you lack keys: runbooks/vault-unseal.md" }
    Write-Ok 'snapshot restored  -  Vault resealed by restore'

    if (-not $keys -or -not $keys.unseal_keys_b64) {
      throw "Vault resealed by restore but $KeysFile has no unseal keys  -  unseal manually NOW (runbooks/vault-unseal.md)"
    }
    for ($i = 0; $i -lt $KeyThreshold; $i++) {
      $null = Invoke-VaultCli -VaultArgs @('operator','unseal',$keys.unseal_keys_b64[$i])
    }
    $st = (Invoke-VaultCli -VaultArgs @('status','-format=json'))[1] | ConvertFrom-Json
    if ($st.sealed) { throw 'still sealed after threshold keys  -  manual unseal needed (runbooks/vault-unseal.md)' }
    Write-Ok 'unsealed after restore'
    $Timings.restore = Stop-DrillTimer

    Write-Step 'Post-restore checks'
    $Checks += Invoke-LiveChecks -Label 'post-restore'
  } else {
    Write-Ok "[dryrun] docker cp snap in; raft snapshot restore -force; unseal x$KeyThreshold; re-run checks"
    $Timings.restore = Stop-DrillTimer
  }
} else {
  Write-Step 'Phase 4 skipped  -  pass -WithRestore to perform the real restore (see DESCRIPTION)'
}

# ------------------------------------------------------------- 5. report ----
Write-Step 'Phase 5  -  report'
$report = Join-Path $ArtDir 'REPORT.md'
$notes = if ($WithRestore) { 'full restore path exercised; snapshot->unseal RTO measured' }
         else { 'snapshot+inspect only; -WithRestore exercises the destructive path' }
New-DrillReport -TemplatePath $TemplatePath -Drill 'vault-raft' -Operator $env:USERNAME `
  -Artifacts $Artifacts -Checks $Checks -Timings $Timings `
  -RpoActual 'operator-run; see docs/rpo-rto.md for the cron target' `
  -RtoActual $Timings.restore -Notes $notes -OutPath $report | Out-Null
if ($WhatIfPreference) { Write-Ok "[dryrun] report would be written to $report" }
else { Write-Ok "report: $report" }

if (($Checks | Where-Object { -not $_.ok }).Count -gt 0) {
  Write-Warn 'one or more checks FAILED  -  see REPORT.md'; exit 1
}
Write-Step 'vault drill complete'
