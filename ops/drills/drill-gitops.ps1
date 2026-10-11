<#
.SYNOPSIS
  Argo CD / Gitea backup+restore drill (docs/rpo-rto.md).
.DESCRIPTION
  What is actually being protected here  -  be precise about it:

    * Gitea stores the xenomit organization repositories. Their contents are
      the local xenomit-platform, xenomit-platform-gitea, and
      xenomit-platform-argocd checkouts, which bootstrap.ps1 syncs with Gitea.
      The drill still backs Gitea up because its git history and users are
      not in those checkouts.
    * Argo's desired state = the Application/AppProject objects in the
      argocd namespace + everything gitops manifests create. Backing up
      `kubectl get appproject,applications` plus the repo covers a full
      argo-namespace rebuild: reinstall chart, apply argo-objects.yaml,
      re-push repo, done (exact steps in runbooks/host-reboot-recovery.md).
    * gitea /data PVC (SQLite + repositories)  -  tarred via kubectl cp.
      Restore is documented PVC surgery (runbook), not executed here.

  Phases:
    1. Backup    kubectl cp gitea /data -> .tar; git clone --mirror of the
                 gitops repo via port-forward; kubectl export of argo CRs
    2. Verify    artifact sizes, tar -tf listing, git ls-remote ref count,
                 argo yaml kind: count
    3. Restore   -WithRestore: push the mirror to a THROWAWAY gitea repo
                 (gitops-restore-<ts>) via the REST API + git push --mirror,
                 ls-remote it, then delete it  -  proves the mirror is a
                 complete, pushable copy without touching the real repo
    4. Report    fills report-template.md

  -DryRun: prints every step; no kubectl exec/cp, no port-forward, no files.
.EXAMPLE
  .\drill-gitops.ps1 -DryRun
  .\drill-gitops.ps1
  .\drill-gitops.ps1 -WithRestore    # also proves the mirror pushes cleanly
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [switch]$DryRun,
  [switch]$WithRestore,
  [string]$GiteaNamespace = 'git',
  [string]$ArgoNamespace = 'argocd',
  [string]$GiteaService = 'gitea',
  [string]$Org = 'xenomit',
  [string]$RepoName = 'gitops',
  [int]$LocalPort = 3300,
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
foreach ($t in 'kubectl','git') {
  if (-not (Test-Cmd $t)) { throw "$t is required on PATH" }
}
if ($WhatIfPreference) { Write-Warn 'DRY RUN  -  steps printed, nothing executed.' }
$ArtDir = New-DrillDir -Base $OutDir -Drill 'gitops'
Write-Ok "artifact dir: $ArtDir"

$Artifacts = @(); $Checks = @()
$Timings = @{ backup = 'skipped'; restore = 'skipped'; verify = 'skipped' }
$MirrorDir = Join-Path $ArtDir "$RepoName-mirror.git"
$TarPath   = Join-Path $ArtDir 'gitea-data.tar'
$ArgoYaml  = Join-Path $ArtDir 'argo-objects.yaml'
$pf = $null
$giteaPod = $null; $pw = $null; $adminUser = 'gitops'

if (-not $WhatIfPreference) {
  Write-Step "Resolving gitea pod + credentials"
  $giteaPod = (Invoke-K -KArgs @('get','pod','-n',$GiteaNamespace,'-l','app.kubernetes.io/name=gitea',
                '-o','jsonpath={.items[0].metadata.name}'))[1].Trim()
  if (-not $giteaPod) { throw "no gitea pod found in $GiteaNamespace" }
  $secret = Invoke-K -KArgs @('get','secret','gitops-git','-n',$GiteaNamespace,'-o','json') -AllowFail
  if ($secret[0] -eq 0) {
    $secretData = $secret[1] | ConvertFrom-Json
    if ($secretData.data.username) { $adminUser = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($secretData.data.username)) }
    if ($secretData.data.password) { $pw = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($secretData.data.password)) }
  }
  if (-not $pw) { throw 'gitops-git is required to read the private platform repository.' }
  Write-Ok "gitea pod: $giteaPod (authenticated repository access)"

  Write-Step "port-forward svc/$GiteaService ${LocalPort}:3000 -n $GiteaNamespace"
  $pf = Start-Process -FilePath kubectl -NoNewWindow -PassThru `
          -ArgumentList @('port-forward',"svc/$GiteaService","${LocalPort}:3000",'-n',$GiteaNamespace) `
          -RedirectStandardOutput (Join-Path $env:TEMP 'drill-gitea-pf.out') `
          -RedirectStandardError  (Join-Path $env:TEMP 'drill-gitea-pf.err')
  $up = $false
  foreach ($i in 1..30) {
    if ($pf.HasExited) { throw "kubectl port-forward died early  -  is port $LocalPort taken? (-LocalPort)" }
    try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $LocalPort); $c.Close(); $up = $true; break }
    catch { Start-Sleep -Milliseconds 500 }
  }
  if (-not $up) { throw "port $LocalPort never accepted a connection" }
}

try {
# ------------------------------------------------------------- 1. backup ----
Write-Step 'Phase 1  -  backup'
Start-DrillTimer

# 1a. gitea /data PVC -> tar
if ($PSCmdlet.ShouldProcess("$giteaPod`:/data", "kubectl cp -> $TarPath")) {
  $null = Invoke-K -KArgs @('cp',"${GiteaNamespace}/${giteaPod}:/data",$TarPath,'-c','gitea')
  $Artifacts += @{ path = $TarPath; bytes = (Get-Item $TarPath).Length; note = 'gitea /data PVC (SQLite + bare repos)' }
  Write-Ok ("gitea /data -> {0:N1} KiB" -f ((Get-Item $TarPath).Length/1KB))
} else { Write-Ok "[dryrun] kubectl cp ${GiteaNamespace}/<gitea-pod>:/data $TarPath" }

# 1b. gitops repo -> bare mirror clone
if ($PSCmdlet.ShouldProcess("$Org/$RepoName", "git clone --mirror -> $MirrorDir")) {
  $url = "http://localhost:$LocalPort/$Org/$RepoName.git"
  if ($pw) { $url = "http://${adminUser}:${pw}@localhost:$LocalPort/$Org/$RepoName.git" }
  $null = Invoke-Native git @('clone','--mirror',$url,$MirrorDir)
  $Artifacts += @{ path = $MirrorDir; bytes = ((Get-ChildItem $MirrorDir -Recurse -File | Measure-Object Length -Sum).Sum); note = "bare mirror of $Org/$RepoName" }
  Write-Ok "mirror cloned"
} else { Write-Ok "[dryrun] git clone --mirror http://localhost:$LocalPort/$Org/$RepoName.git" }

# 1c. argo objects -> yaml export
if ($PSCmdlet.ShouldProcess($ArgoNamespace, 'kubectl get argo CRs -o yaml')) {
  $r = Invoke-K -KArgs @('get','appproject,applications,appproject.argoproj.io,applications.argoproj.io','-n',$ArgoNamespace,'-o','yaml') -AllowFail
  if ($r[0] -ne 0) { $r = Invoke-K -KArgs @('get','applications,appprojects','-n',$ArgoNamespace,'-o','yaml') }
  [IO.File]::WriteAllText($ArgoYaml, $r[1])
  $Artifacts += @{ path = $ArgoYaml; bytes = (Get-Item $ArgoYaml).Length; note = 'AppProject + Applications (desired state)' }
  Write-Ok 'argo CRs exported'
} else { Write-Ok "[dryrun] kubectl get appproject,applications -n $ArgoNamespace -o yaml > argo-objects.yaml" }
$Timings.backup = Stop-DrillTimer

# ------------------------------------------------------------- 2. verify ----
Write-Step 'Phase 2  -  point checks'
Start-DrillTimer
if ($PSCmdlet.ShouldProcess($ArtDir, 'artifact verification')) {
  if (Test-Cmd 'tar') {
    $r = Invoke-Native tar @('-tf',$TarPath) -AllowFail
    $entries = ($r[1] -split "`n") | Where-Object { $_.Trim() }
    $Checks += @{ name = 'gitea-data.tar readable'; ok = ($r[0] -eq 0 -and $entries.Count -gt 0); detail = "$($entries.Count) tar entries" }
  } else {
    $Checks += @{ name = 'gitea-data.tar readable'; ok = ((Get-Item $TarPath).Length -gt 0); detail = 'tar not on PATH  -  size check only' }
  }
  $r = Invoke-Native git @('-C',$MirrorDir,'rev-list','--all','--count') -AllowFail
  $commits = $r[1].Trim()
  $Checks += @{ name = 'mirror has commits'; ok = ($r[0] -eq 0 -and $commits -match '^\d+$' -and [int]$commits -gt 0); detail = "$commits commits" }
  $kinds = ([regex]::Matches((Get-Content $ArgoYaml -Raw), '(?m)^kind: (Application|AppProject)$')).Count
  $Checks += @{ name = 'argo yaml has objects'; ok = ($kinds -ge 2); detail = "$kinds Application/AppProject docs" }
  foreach ($c in $Checks) { Write-Ok "$(if($c.ok){'PASS'}else{'FAIL'}) $($c.name)  -  $($c.detail)" }
} else { Write-Ok '[dryrun] tar -tf, git rev-list --count, kind: count' }
$Timings.verify = Stop-DrillTimer

# ------------------------------------------------------------- 3. restore ---
if ($WithRestore) {
  Write-Step 'Phase 3  -  restore proof: push mirror to a throwaway repo, verify, delete'
  $restoreRepo = "gitops-restore-$(Get-Date -Format 'yyyyMMddHHmmss')"
  Start-DrillTimer
  if ($PSCmdlet.ShouldProcess($restoreRepo, 'create repo + push --mirror + ls-remote + delete')) {
    if (-not $pw) { throw '-WithRestore needs the gitops-git secret (write access)  -  anonymous cannot create repos' }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${adminUser}:${pw}"))
    $hdr = @{ Authorization = "Basic $b64" }
    $body = @{ name = $restoreRepo; private = $false; auto_init = $false; default_branch = 'main' } | ConvertTo-Json
    $null = Invoke-RestMethod -Headers $hdr -Method Post -ContentType 'application/json' `
            -Uri "http://localhost:$LocalPort/api/v1/user/repos" -Body $body -TimeoutSec 15
    try {
      $pushUrl = "http://${adminUser}:${pw}@localhost:$LocalPort/$adminUser/$restoreRepo.git"
      $null = Invoke-Native git @('-C',$MirrorDir,'push','--mirror',$pushUrl)
      $r = Invoke-Native git @('ls-remote',$pushUrl)
      $refCount = @($r[1] -split "`n" | Where-Object { $_.Trim() }).Count
      $Checks += @{ name = 'mirror pushed+listed'; ok = ($refCount -gt 0); detail = "$refCount refs on $restoreRepo" }
      $Artifacts += @{ path = "gitea:$adminUser/$restoreRepo"; bytes = 0; note = 'throwaway restore target (deleted after check)' }
      Write-Ok "pushed mirror; $refCount refs visible"
    } finally {
      $null = Invoke-RestMethod -Headers $hdr -Method Delete `
              -Uri "http://localhost:$LocalPort/api/v1/repos/$adminUser/$restoreRepo" -TimeoutSec 15
      Write-Ok "throwaway repo $restoreRepo deleted"
    }
  } else {
    Write-Ok "[dryrun] POST /api/v1/user/repos {$restoreRepo}; git push --mirror; ls-remote; DELETE repo"
  }
  $Timings.restore = Stop-DrillTimer
} else {
  Write-Step 'Phase 3 skipped  -  pass -WithRestore to prove the mirror pushes cleanly'
}

} finally {
  if ($pf) { Stop-Process -Id $pf.Id -Force -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------- 4. report ----
Write-Step 'Phase 4  -  report'
$report = Join-Path $ArtDir 'REPORT.md'
$notes = 'PVC tar restore is documented surgery (runbooks/host-reboot-recovery.md), not drilled  -  k3s local-path PVs have no portable in-place restore. ' +
         'Remember: Gitea repository contents come from the local checkouts; commit them and run bootstrap.ps1 (or open a pull request).'
New-DrillReport -TemplatePath $TemplatePath -Drill 'gitops-argocd' -Operator $env:USERNAME `
  -Artifacts $Artifacts -Checks $Checks -Timings $Timings `
  -RpoActual 'repo = generated mirror; PVC tar is operator-run' `
  -RtoActual $Timings.restore -Notes $notes -OutPath $report | Out-Null
if ($WhatIfPreference) { Write-Ok "[dryrun] report would be written to $report" }
else { Write-Ok "report: $report" }

if (($Checks | Where-Object { -not $_.ok }).Count -gt 0) {
  Write-Warn 'one or more checks FAILED  -  see REPORT.md'; exit 1
}
Write-Step 'gitops drill complete'
