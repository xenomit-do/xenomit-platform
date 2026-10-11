<#
.SYNOPSIS
  Shared helpers for the ops/drills backup/restore drill scripts.
.DESCRIPTION
  Dot-sourced by drill-postgres.ps1 / drill-vault.ps1 / drill-gitops.ps1.
  NOT meant to be run directly. Mirrors the conventions of
  ops/vault/vault-init.ps1:
    - Invoke-Native wraps every external call so PS 5.1's
      NativeCommandError-on-stderr can't wedge ErrorActionPreference=Stop.
    - Write-Step/Write-Warn/Write-Ok give uniform sectioned output.
    - Start-DrillTimer/Stop-DrillTimer measure each phase so the report can
      record real RTO numbers.
    - New-DrillReport renders a filled copy of report-template.md.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string]$Msg) { Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Write-Warn([string]$Msg) { Write-Host "!!  $Msg" -ForegroundColor Yellow }
function Write-Ok([string]$Msg)   { Write-Host "    $Msg" -ForegroundColor Green }
function Test-Cmd([string]$Name)  { return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue) }

# Every external command goes through here. Returns @($exitCode, $output).
function Invoke-Native {
  param(
    [Parameter(Mandatory)][string]$Exe,
    [string[]]$NativeArgs = @(),
    [string]$Stdin,
    [switch]$AllowFail
  )
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($null -ne $Stdin) { $out = $Stdin | & $Exe @NativeArgs 2>&1 | Out-String }
    else                  { $out =          & $Exe @NativeArgs 2>&1 | Out-String }
    $rc = $LASTEXITCODE
  } finally { $ErrorActionPreference = $prev }
  if ($rc -ne 0 -and -not $AllowFail) { throw "$Exe $($NativeArgs -join ' ') failed (exit ${rc}):`n$out" }
  return ,@($rc, $out)
}

function Invoke-K {
  param([string[]]$KArgs, [string]$Stdin, [switch]$AllowFail)
  $r = Invoke-Native kubectl $KArgs -Stdin $Stdin -AllowFail:$AllowFail
  if ($r[0] -ne 0 -and -not $AllowFail) { throw "kubectl $($KArgs -join ' ') failed:`n$($r[1])" }
  return $r
}

# --- phase timing: drills report real backup/restore durations --------------
$script:DrillTimer = $null
function Start-DrillTimer { $script:DrillTimer = [Diagnostics.Stopwatch]::StartNew() }
function Stop-DrillTimer {
  if ($null -eq $script:DrillTimer) { return 'n/a' }
  $script:DrillTimer.Stop()
  return ('{0:hh\:mm\:ss\.f}' -f $script:DrillTimer.Elapsed)
}

# --- artifact dir: one timestamped dir per drill run ------------------------
function New-DrillDir([string]$Base, [string]$Drill) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $dir = Join-Path $Base "$Drill-$stamp"
  $null = New-Item -ItemType Directory -Force -Path $dir
  return $dir
}

# --- report: fills report-template.md placeholders --------------------------
# $Checks = array of @{ name=...; ok=$true/$false; detail=... }
function New-DrillReport {
  param(
    [string]$TemplatePath,
    [string]$Drill,
    [string]$Operator,
    [array]$Artifacts,          # @{ path=...; bytes=...; note=... }
    [array]$Checks,             # @{ name=...; ok=...; detail=... }
    [hashtable]$Timings,        # @{ backup=..; restore=..; verify=.. }
    [string]$RpoActual, [string]$RtoActual,
    [string]$Notes,
    [string]$OutPath
  )
  $tpl = Get-Content $TemplatePath -Raw
  $art = ($Artifacts | ForEach-Object {
    $sz = if ($_.bytes -ge 1MB) { '{0:N1} MiB' -f ($_.bytes / 1MB) }
          elseif ($_.bytes -ge 1KB) { '{0:N1} KiB' -f ($_.bytes / 1KB) }
          else { "$($_.bytes) B" }
    "| ``$($_.path)`` | $sz | $($_.note) |"
  }) -join "`n"
  $chk = ($Checks | ForEach-Object {
    $mark = if ($_.ok) { 'PASS' } else { 'FAIL' }
    "| $mark | $($_.name) | $($_.detail) |"
  }) -join "`n"
  $overall = if ($Checks.Count -gt 0 -and ($Checks | Where-Object { -not $_.ok }).Count -eq 0) { 'PASS' } else { 'FAIL' }
  $tpl = $tpl.Replace('__DRILL__', $Drill).
              Replace('__DATE__', (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')).
              Replace('__OPERATOR__', $Operator).
              Replace('__ARTIFACTS__', $art).
              Replace('__CHECKS__', $chk).
              Replace('__BACKUP_TIME__',  $Timings.backup).
              Replace('__RESTORE_TIME__', $Timings.restore).
              Replace('__VERIFY_TIME__',  $Timings.verify).
              Replace('__RPO_ACTUAL__', $RpoActual).
              Replace('__RTO_ACTUAL__', $RtoActual).
              Replace('__OVERALL__', $overall).
              Replace('__NOTES__', $Notes)
  [IO.File]::WriteAllText($OutPath, $tpl)
  return $OutPath
}
