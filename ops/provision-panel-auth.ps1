#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$Namespace = 'xenomit-system',
  [string]$SecretName = 'xenomit-panel-auth',
  [string]$VaultPath = 'secret/infra/panel-auth',
  [string]$VaultContainer = 'xenomit-vault',
  [string]$KeysFile = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$OpsDir = $PSScriptRoot
$VaultDir = Join-Path $OpsDir 'vault'
if (-not $KeysFile) { $KeysFile = Join-Path $VaultDir 'cluster-keys.json' }

function Write-Step([string]$Msg) { Write-Host ('==> ' + $Msg) -ForegroundColor Cyan }
function Write-Ok([string]$Msg)   { Write-Host ('    ' + $Msg) -ForegroundColor Green }
function Write-Warn([string]$Msg) { Write-Host ('!!  ' + $Msg) -ForegroundColor Yellow }

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
    else { $out = & $Exe @NativeArgs 2>&1 | Out-String }
    $rc = $LASTEXITCODE
  } finally { $ErrorActionPreference = $prev }
  if ($rc -ne 0 -and -not $AllowFail) {
    throw ($Exe + ' ' + ($NativeArgs -join ' ') + ' failed (exit ' + $rc + '):' + [Environment]::NewLine + $out)
  }
  return ,@($rc, $out)
}

function Assert-PanelAuthSecret([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { throw 'Vault panel auth secret is empty.' }
  try { $bytes = [Convert]::FromBase64String($Value) }
  catch { throw 'Vault panel auth secret is not valid base64.' }
  if ($bytes.Length -ne 32) {
    [Array]::Clear($bytes,0,$bytes.Length)
    throw 'Vault panel auth secret must decode to 32 bytes; refusing to sync it.'
  }
  [Array]::Clear($bytes,0,$bytes.Length)
}

Write-Step ('Vault-backed panel authentication secret (' + $SecretName + ' -n ' + $Namespace + ')')
if (-not (Test-Path -LiteralPath $KeysFile)) { throw "Vault credentials file missing: $KeysFile (run ops/vault/vault-init.ps1 first)." }
$keys = Get-Content -LiteralPath $KeysFile -Raw | ConvertFrom-Json
$vaultToken = if ($keys.ops_token -and $keys.ops_token -ne '(revoked)') { [string]$keys.ops_token } else { '' }
if (-not $vaultToken) { throw 'No usable Vault ops token in cluster-keys.json.' }
if (-not $env:TEMP) { throw 'TEMP is not set; cannot create a temporary secret file.' }

$oldVaultToken = $env:VAULT_TOKEN
$env:VAULT_TOKEN = $vaultToken
$tempDir = Join-Path $env:TEMP ('xenomit-panel-auth-' + [Guid]::NewGuid().ToString('N'))
$hostSecretPath = Join-Path $tempDir 'auth-secret'
$containerSecretPath = '/tmp/xenomit-panel-auth-' + [Guid]::NewGuid().ToString('N')
$containerFileCopied = $false
$rng = $null
$randomBytes = $null
try {
  $vaultRead = Invoke-Native docker @(
    'exec','-e','VAULT_TOKEN',$VaultContainer,'vault','kv','get','-field=auth-secret',$VaultPath
  ) -AllowFail

  if ($vaultRead[0] -eq 0) {
    $authSecret = ([string]$vaultRead[1]).Trim()
    Assert-PanelAuthSecret $authSecret
    Write-Ok ('loaded the existing panel key from Vault at ' + $VaultPath)
  } else {
    if ($vaultRead[1] -notmatch '(?i)No value found at') {
      throw ('Could not read Vault path ' + $VaultPath + ': ' + ([string]$vaultRead[1]).Trim())
    }

    $existingK8s = Invoke-Native kubectl @('get','secret',$SecretName,'-n',$Namespace,'-o','json') -AllowFail
    $currentKey = $null
    if ($existingK8s[0] -eq 0) {
      $currentObject = $existingK8s[1] | ConvertFrom-Json
      $currentKey = $currentObject.data.PSObject.Properties['AUTH_SECRET']
    }

    if ($null -ne $currentKey -and -not [string]::IsNullOrWhiteSpace([string]$currentKey.Value)) {
      $currentBytes = [Convert]::FromBase64String([string]$currentKey.Value)
      try { $authSecret = [Text.Encoding]::UTF8.GetString($currentBytes) }
      finally { [Array]::Clear($currentBytes,0,$currentBytes.Length) }
      Assert-PanelAuthSecret $authSecret
      Write-Ok 'Vault has no panel key; preserving and importing the existing Kubernetes key'
    } else {
      $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
      $randomBytes = New-Object byte[] 32
      $rng.GetBytes($randomBytes)
      $authSecret = [Convert]::ToBase64String($randomBytes)
      Write-Ok 'Vault has no panel key; generated a random 256-bit key'
    }

    if (-not $PSCmdlet.ShouldProcess(('Vault KV ' + $VaultPath), 'persist the panel Auth.js key')) { return }
    $null = New-Item -ItemType Directory -Path $tempDir
    [IO.File]::WriteAllText($hostSecretPath,$authSecret,[Text.Encoding]::ASCII)
    $null = Invoke-Native docker @('cp',$hostSecretPath,($VaultContainer + ':' + $containerSecretPath))
    $containerFileCopied = $true
    $null = Invoke-Native docker @(
      'exec','-e','VAULT_TOKEN',$VaultContainer,'vault','kv','put',$VaultPath,('auth-secret=@' + $containerSecretPath)
    )
    Write-Ok ('stored the panel key in Vault at ' + $VaultPath)
  }

  $desiredK8sValue = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($authSecret))
  $existingK8s = Invoke-Native kubectl @('get','secret',$SecretName,'-n',$Namespace,'-o','json') -AllowFail
  $currentK8sValue = ''
  if ($existingK8s[0] -eq 0) {
    $currentObject = $existingK8s[1] | ConvertFrom-Json
    $currentKey = $currentObject.data.PSObject.Properties['AUTH_SECRET']
    if ($null -ne $currentKey) { $currentK8sValue = [string]$currentKey.Value }
  }

  if ($currentK8sValue -eq $desiredK8sValue) {
    Write-Ok ('Kubernetes Secret/' + $SecretName + ' already matches Vault')
  } else {
    if (-not $PSCmdlet.ShouldProcess(('Secret/' + $SecretName + ' -n ' + $Namespace), 'sync AUTH_SECRET from Vault')) { return }
    if (-not (Test-Path -LiteralPath $tempDir)) { $null = New-Item -ItemType Directory -Path $tempDir }
    [IO.File]::WriteAllText($hostSecretPath,$authSecret,[Text.Encoding]::ASCII)
    $manifest = Invoke-Native kubectl @(
      'create','secret','generic',$SecretName,'-n',$Namespace,('--from-file=AUTH_SECRET=' + $hostSecretPath),
      '--dry-run=client','-o','yaml'
    )
    $null = Invoke-Native kubectl @('apply','-f','-') -Stdin $manifest[1]
    Write-Ok ('synced Secret/' + $SecretName + ' from Vault')

    $deployment = Invoke-Native kubectl @('get','deployment','xenomit-web-panel','-n',$Namespace,'-o','name') -AllowFail
    if ($deployment[0] -eq 0 -and $deployment[1].Trim()) {
    $restart = Invoke-Native kubectl @('rollout','restart','deployment/xenomit-web-panel','-n',$Namespace) -AllowFail
    if ($restart[0] -eq 0) { Write-Ok 'restarted the panel so it reads the updated secret' }
    else { Write-Warn 'panel secret is updated; restart was skipped because the current image cannot be admitted yet' }
    }
  }
} finally {
  if ($containerFileCopied) {
    $null = Invoke-Native docker @('exec','-e','VAULT_TOKEN',$VaultContainer,'rm','-f',$containerSecretPath) -AllowFail
  }
  if ($rng) { $rng.Dispose() }
  if ($randomBytes) { [Array]::Clear($randomBytes,0,$randomBytes.Length) }
  if (Test-Path -LiteralPath $tempDir) {
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $resolvedTemp = [IO.Path]::GetFullPath($tempDir)
    if (-not $resolvedTemp.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $resolvedTemp -Leaf) -notmatch '^xenomit-panel-auth-[0-9a-f]{32}$') {
      throw 'Refusing to remove a temporary secret path outside the generated temp directory.'
    }
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
  if ($null -eq $oldVaultToken) { Remove-Item Env:\VAULT_TOKEN -ErrorAction SilentlyContinue }
  else { $env:VAULT_TOKEN = $oldVaultToken }
  Remove-Variable authSecret, vaultToken, keys, existingK8s, currentObject, currentKey, desiredK8sValue, currentK8sValue -ErrorAction SilentlyContinue
}
