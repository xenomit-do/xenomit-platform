<#
.SYNOPSIS
  Postgres backup/restore drill (docs/rpo-rto.md). pg_dump -> restore into a
  SCRATCH database -> point checks -> drop the scratch.
.DESCRIPTION
  Non-destructive by design: restore always targets a throwaway database
  (`xenomit_drill_<timestamp>`) on the same server  -  never the live
  xenomit_orchestrator / xenomit_panel databases  -  so the full restore path is
  genuinely exercised without touching real data. The scratch is dropped even
  on failure (finally block).

  Covers BOTH databases on the shared instance (ops/k8s/30-postgres.yaml):
    xenomit_orchestrator   -  snapshots, stats, audit (ADR-05/22 state)
    xenomit_panel          -  accounts, plans, tokens (docs/08, docs/12)

  Phases:
    1. Backup    pg_dump (plain SQL) per database, streamed out via kubectl
                 exec stdout -> ops/drills/out/postgres-<ts>/<db>.sql
    2. Restore   CREATE DATABASE scratch; psql < dump; repeat per database
    3. Checks    table-count parity + per-table row-count parity (capped at
                 100 tables) between source and scratch
    4. Report    fills report-template.md into the artifact dir

  -DryRun (-WhatIf semantics): prints every step and the files it WOULD
  write; zero kubectl exec mutations, zero file output beyond the artifact
  dir itself.

  Prerequisites: kubectl context points at the xenomit cluster; pod
  postgres-0 Ready. Nothing is installed.
.EXAMPLE
  .\drill-postgres.ps1 -DryRun
  .\drill-postgres.ps1                      # backup + scratch restore + checks
  .\drill-postgres.ps1 -SkipRestore         # backup only (RPO snapshot)
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [switch]$DryRun,
  [switch]$SkipRestore,
  [string]$Namespace = 'xenomit-data',
  [string]$Pod = 'postgres-0',
  [string]$SecretName = 'postgres-auth',
  [string[]]$Databases = @('xenomit_orchestrator', 'xenomit_panel'),
  [string]$OutDir = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($DryRun) { $WhatIfPreference = $true }

. (Join-Path $PSScriptRoot 'lib-drill.ps1')

if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'out' }
$TemplatePath = Join-Path $PSScriptRoot 'report-template.md'

# ------------------------------------------------------------- prereqs ------
Write-Step 'Prerequisites'
foreach ($t in 'kubectl') {
  if (-not (Test-Cmd $t)) { throw "$t is required on PATH" }
}
if ($WhatIfPreference) {
  Write-Warn 'DRY RUN  -  the steps below are printed, not executed. No exec calls, no files, no scratch database.'
}

$ArtDir = New-DrillDir -Base $OutDir -Drill 'postgres'
Write-Ok "artifact dir: $ArtDir"

$pgUser = $null
if (-not $WhatIfPreference) {
  Write-Step "Resolving postgres superuser from secret/$SecretName"
  $r = Invoke-K -KArgs @('get','secret',$SecretName,'-n',$Namespace,'-o','jsonpath={.data.POSTGRES_USER}')
  if (-not $r[1].Trim()) { throw "secret/$SecretName has no POSTGRES_USER" }
  $pgUser = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($r[1].Trim()))

  Write-Step "Waiting for pod/$Pod"
  $null = Invoke-K -KArgs @('wait',"--for=condition=Ready","pod/$Pod",'-n',$Namespace,'--timeout=60s')
  Write-Ok "superuser '$pgUser', pod ready"
} else {
  Write-Step "[dryrun] would read $SecretName/POSTGRES_USER and wait for pod/$Pod in $Namespace"
}

# Run psql/pg_dump inside the postgres pod. Peer auth on the local socket  - 
# no password ever leaves the secret.
function Invoke-Pg {
  param([string[]]$PgArgs, [string]$Stdin, [switch]$AllowFail)
  return (Invoke-K -KArgs (@('exec','-i',$Pod,'-n',$Namespace,'--') + $PgArgs) -Stdin $Stdin -AllowFail:$AllowFail)
}

$Artifacts = @()
$Checks    = @()
$Timings   = @{ backup = 'skipped'; restore = 'skipped'; verify = 'skipped' }
$Dumps     = @{}   # db -> dump path (also holds the SQL text for stdin replay)

# ------------------------------------------------------------- 1. backup ----
Write-Step 'Phase 1  -  pg_dump backup'
Start-DrillTimer
foreach ($db in $Databases) {
  $out = Join-Path $ArtDir "$db.sql"
  if ($PSCmdlet.ShouldProcess("$Pod/$db", "pg_dump -> $out")) {
    $r = Invoke-Pg -PgArgs @('pg_dump','-U',$pgUser,'--no-owner','--no-privileges',$db)
    if ($r[0] -ne 0 -or -not $r[1].Trim()) { throw "pg_dump $db produced no output:`n$($r[1])" }
    [IO.File]::WriteAllText($out, $r[1])
    $Dumps[$db] = $out
    $bytes = (Get-Item $out).Length
    $Artifacts += @{ path = $out; bytes = $bytes; note = "pg_dump of $db (plain SQL)" }
    Write-Ok ("{0}: {1:N1} KiB -> {2}" -f $db, ($bytes/1KB), $out)
  } else {
    Write-Ok "[dryrun] pg_dump -U <user> --no-owner --no-privileges $db -> $out"
  }
}
$Timings.backup = Stop-DrillTimer

# ------------------------------------------------------------ 2. restore ----
$Scratch = "xenomit_drill_$(Get-Date -Format 'yyyyMMddHHmmss')"
try {
if (-not $SkipRestore) {
  Write-Step "Phase 2  -  restore into scratch database '$Scratch' (never the live DBs)"
  Start-DrillTimer
  foreach ($db in $Databases) {
    $scratchDb = "${Scratch}_$($db -replace '[^a-z0-9_]','')"
    if ($PSCmdlet.ShouldProcess($scratchDb, 'CREATE DATABASE + psql restore')) {
      $null = Invoke-Pg -PgArgs @('psql','-U',$pgUser,'-d','postgres','-v','ON_ERROR_STOP=1','-c',"CREATE DATABASE `"$scratchDb`"")
      $sql = [IO.File]::ReadAllText($Dumps[$db])
      $r = Invoke-Pg -PgArgs @('psql','-U',$pgUser,'-d',$scratchDb,'-v','ON_ERROR_STOP=1','-q') -Stdin $sql -AllowFail
      if ($r[0] -ne 0) { throw "restore into $scratchDb failed:`n$($r[1])" }
      $Artifacts += @{ path = "db:$scratchDb"; bytes = 0; note = "scratch restore of $db (dropped at end)" }
      Write-Ok "restored $db -> $scratchDb"
    } else {
      Write-Ok "[dryrun] CREATE DATABASE $scratchDb; psql < $db.sql"
    }
  }
  $Timings.restore = Stop-DrillTimer

  # ------------------------------------------------------------ 3. checks ----
  Write-Step 'Phase 3  -  point checks (source vs scratch parity)'
  Start-DrillTimer
  foreach ($db in $Databases) {
    $scratchDb = "${Scratch}_$($db -replace '[^a-z0-9_]','')"
    if ($PSCmdlet.ShouldProcess($scratchDb, 'row/table count parity checks')) {
      # Table-count parity.
      $q = "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'"
      $src = (Invoke-Pg -PgArgs @('psql','-U',$pgUser,'-d',$db,'-Atc',$q))[1].Trim()
      $dst = (Invoke-Pg -PgArgs @('psql','-U',$pgUser,'-d',$scratchDb,'-Atc',$q))[1].Trim()
      $ok = ($src -eq $dst) -and ($src -match '^\d+$')
      $Checks += @{ name = "$db table count"; ok = $ok; detail = "source=$src scratch=$dst" }
      Write-Ok "$db tables: source=$src scratch=$dst $(if($ok){'PASS'}else{'FAIL'})"

      # Per-table row-count parity, capped at 100 tables. Builds one UNION ALL
      # query so it is a single round-trip per database.
      $tables = ((Invoke-Pg -PgArgs @('psql','-U',$pgUser,'-d',$db,'-Atc',
        "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY 1 LIMIT 100"))[1] -split "`n") |
        ForEach-Object { $_.Trim() } | Where-Object { $_ }
      if ($tables.Count -gt 0) {
        $union = (($tables | ForEach-Object { "SELECT '$_' AS t, count(*) AS n FROM `"$_`"" }) -join ' UNION ALL ') + ' ORDER BY 1'
        $srcRows = (Invoke-Pg -PgArgs @('psql','-U',$pgUser,'-d',$db,'-Atc',$union))[1]
        $dstRows = (Invoke-Pg -PgArgs @('psql','-U',$pgUser,'-d',$scratchDb,'-Atc',$union))[1]
        $ok2 = ($srcRows -eq $dstRows) -and ($srcRows.Trim().Length -gt 0)
        $diff = ''
        if (-not $ok2) {
          $s = @{}; ($srcRows -split "`n") | ForEach-Object { $p = $_ -split '\|'; if ($p.Count -eq 2) { $s[$p[0]] = $p[1] } }
          ($dstRows -split "`n") | ForEach-Object { $p = $_ -split '\|'; if ($p.Count -eq 2 -and $s[$p[0]] -ne $p[1]) { $diff += " $($p[0])" } }
          if (-not $diff) { $diff = ' (could not diff  -  see artifacts)' }
        }
        $Checks += @{ name = "$db row counts ($($tables.Count) tables)"; ok = $ok2; detail = "identical UNION-ALL output$diff" }
        Write-Ok "$db row parity: $(if($ok2){'PASS'}else{"FAIL  -  differing tables:$diff"})"
      } else {
        $Checks += @{ name = "$db row counts"; ok = $true; detail = 'no public tables  -  nothing to compare' }
      }
    } else {
      Write-Ok "[dryrun] compare information_schema + per-table counts, $db vs $scratchDb"
    }
  }
  $Timings.verify = Stop-DrillTimer
} else {
  Write-Step 'Phases 2-3 skipped (-SkipRestore): backup-only run'
}
} finally {
  # Always clean up scratch DBs  -  even on failure mid-drill.
  if (-not $SkipRestore -and -not $WhatIfPreference) {
    Write-Step 'Cleanup  -  dropping scratch databases'
    foreach ($db in $Databases) {
      $scratchDb = "${Scratch}_$($db -replace '[^a-z0-9_]','')"
      if ($PSCmdlet.ShouldProcess($scratchDb, 'DROP DATABASE')) {
        $null = Invoke-Pg -PgArgs @('psql','-U',$pgUser,'-d','postgres','-c',"DROP DATABASE IF EXISTS `"$scratchDb`"") -AllowFail
      }
    }
  }
}

# ------------------------------------------------------------- 4. report ----
Write-Step 'Phase 4  -  report'
$report = Join-Path $ArtDir 'REPORT.md'
$rpoNote = if ($SkipRestore) { 'backup-only run  -  restore path not exercised' } else { 'scratch-DB restore  -  live data untouched' }
New-DrillReport -TemplatePath $TemplatePath -Drill 'postgres' -Operator $env:USERNAME `
  -Artifacts $Artifacts -Checks $Checks -Timings $Timings `
  -RpoActual 'dump frequency is operator-run; see docs/rpo-rto.md' `
  -RtoActual "scratch restore $($Timings.restore)" -Notes $rpoNote -OutPath $report | Out-Null
if ($WhatIfPreference) { Write-Ok "[dryrun] report would be written to $report" }
else { Write-Ok "report: $report" }

if (($Checks | Where-Object { -not $_.ok }).Count -gt 0) {
  Write-Warn 'one or more checks FAILED  -  see REPORT.md'; exit 1
}
Write-Step 'postgres drill complete'
