<#
.SYNOPSIS
  Tear down the local platform.
.DESCRIPTION
  Deletes the k3d cluster xenomit. That removes the server container and the
  Docker volume mounted at /var/lib/rancher/k3s, which is where every PVC
  directory lives, plus the registry container and k3d-xenomit-images.

  Vault DATA is kept unless -RemoveVaultData is set. With that switch the
  script also deletes the named volume xenomit-vault_vault-data and
  ops/vault/cluster-keys.json. TLS files under ops/vault/tls are kept.

  The local OpenTofu state of the minimal bootstrap and the admin stacks
  (bootstrap/*, stacks/*) is deleted with the cluster because it describes objects
  that no longer exist.
  The state of the platform stacks lives in a Secret inside the cluster and goes
  with it.

  Host paths are printed before anything is deleted. The volume id in the
  k3s path changes every time the cluster is created.
.EXAMPLE
  .\teardown.ps1                    # cluster gone, vault data and unseal keys kept
  .\teardown.ps1 -RemoveVaultData   # cluster, PVC data, vault volume, and unseal keys gone
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
  [string]$ClusterName = 'xenomit',
  [switch]$RemoveVaultData,
  # NB: $PSScriptRoot is empty inside param() defaults when invoked via
  # powershell.exe -File -- resolve it in the body instead.
  [string]$ComposeFile = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $ComposeFile) { $ComposeFile = Join-Path $PSScriptRoot 'vault\docker-compose.yml' }

function Write-Step([string]$Msg) { Write-Host "==> $Msg" -ForegroundColor Cyan }
function Write-Warn([string]$Msg) { Write-Host "!!  $Msg" -ForegroundColor Yellow }

# PS 5.1 turns stderr output of a native command into a terminating
# NativeCommandError under ErrorActionPreference=Stop. Route external calls
# through this wrapper.
function Invoke-Native {
  param(
    [Parameter(Mandatory)][string]$Exe,
    [string[]]$NativeArgs = @(),
    [switch]$AllowFail
  )
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $Exe @NativeArgs 2>&1 | Out-String -Width 65536
    $rc = $LASTEXITCODE
  } finally { $ErrorActionPreference = $prev }
  if ($rc -ne 0 -and -not $AllowFail) { throw "$Exe $($NativeArgs -join ' ') failed (exit ${rc}):`n$out" }
  return ,@($rc, $out)
}

function Get-WindowsDockerVolume([string]$VolumeName) {
  if (-not $VolumeName) { return $null }
  return "\\wsl$\docker-desktop\mnt\docker-desktop-disk\data\docker\volumes\$VolumeName\_data"
}

function Get-ContainerVolumeName([string]$Container, [string]$Destination) {
  $raw = Invoke-Native docker @('inspect',$Container,'--format','{{json .Mounts}}') -AllowFail
  if ($raw[0] -ne 0 -or -not $raw[1].Trim()) { return $null }
  try {
    $mounts = $raw[1].Trim() | ConvertFrom-Json
  } catch { return $null }
  foreach ($m in $mounts) {
    if ([string]$m.Destination -eq $Destination) { return [string]$m.Name }
  }
  return $null
}

function Write-HostPaths {
  Write-Step 'Host paths'
  $server = "k3d-$ClusterName-server-0"
  $k3sName = Get-ContainerVolumeName $server '/var/lib/rancher/k3s'
  if ($k3sName) {
    $storage = Join-Path (Get-WindowsDockerVolume $k3sName) 'storage'
    Write-Host "    PVC directories: $storage"
  } else {
    Write-Host "    PVC directories: $server is not running, so there is no k3s volume to print"
  }
  $registryName = Get-ContainerVolumeName 'xenomit-registry' '/var/lib/registry'
  if ($registryName) {
    Write-Host "    registry: $(Get-WindowsDockerVolume $registryName)"
  }
  $images = Get-WindowsDockerVolume "k3d-$ClusterName-images"
  Write-Host "    k3d image volume: $images"
  $vault = Get-WindowsDockerVolume 'xenomit-vault_vault-data'
  Write-Host "    Vault Raft: $vault"
  $keys = Join-Path (Split-Path $ComposeFile -Parent) 'cluster-keys.json'
  Write-Host "    unseal keys: $keys"
}

Write-HostPaths

if (Get-Command k3d -ErrorAction SilentlyContinue) {
  if ($PSCmdlet.ShouldProcess("k3d cluster $ClusterName", 'k3d cluster delete')) {
    Write-Step "Deleting k3d cluster $ClusterName"
    $null = Invoke-Native k3d @('cluster','delete',$ClusterName) -AllowFail
  }
} else {
  Write-Warn 'k3d not installed -- skipping cluster delete'
}

# Local OpenTofu state describes the cluster that was just deleted: the minimal bootstrap
# (bootstrap/*) and the admin stacks (stacks/*). Keep .terraform (downloaded providers) so the
# next bootstrap starts faster. The platform stacks keep their state in the cluster.
$platformDir = Split-Path $PSScriptRoot -Parent
$stateFiles = @(foreach ($sub in 'bootstrap', 'stacks') {
  $d = Join-Path $platformDir $sub
  if (Test-Path $d) { Get-ChildItem $d -Recurse -Include 'terraform.tfstate','terraform.tfstate.backup' -ErrorAction SilentlyContinue }
})
if ($stateFiles.Count -gt 0 -and $PSCmdlet.ShouldProcess("$($stateFiles.Count) local OpenTofu state file(s)", 'remove')) {
  Write-Step 'Removing local OpenTofu state'
  $stateFiles | Remove-Item -Force
}

if (Get-Command docker -ErrorAction SilentlyContinue) {
  $downArgs = @('compose','-f',$ComposeFile,'down')
  $what = 'vault container (data volume kept)'
  if ($RemoveVaultData) {
    $downArgs += '-v'
    $what = 'vault container + volume (CREDENTIALS DESTROYED)'
  }
  if ($PSCmdlet.ShouldProcess($what, 'docker compose down')) {
    Write-Step "docker compose down $what"
    $null = Invoke-Native docker $downArgs -AllowFail
  }
  if ($RemoveVaultData) {
    $keys = Join-Path (Split-Path $ComposeFile -Parent) 'cluster-keys.json'
    if ((Test-Path $keys) -and $PSCmdlet.ShouldProcess($keys, 'remove unseal keys')) {
      Remove-Item -Force $keys
      Write-Step "Removed $keys"
    }
  }
} else {
  Write-Warn 'docker not installed -- skipping vault stop'
}

if ($RemoveVaultData) {
  Write-Step 'Done. Cluster volumes, the Vault Raft volume, and cluster-keys.json are removed. TLS files under ops/vault/tls are kept.'
} else {
  Write-Step 'Done. Vault data and ops/vault/cluster-keys.json are still on disk.'
}
