#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$Namespace = 'xenomit-system',
  [string]$SecretName = 'xenomit-api-jwt'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string]$Msg) { Write-Host ('==> ' + $Msg) -ForegroundColor Cyan }
function Write-Ok([string]$Msg)   { Write-Host ('    ' + $Msg) -ForegroundColor Green }

function Invoke-Native {
  param([Parameter(Mandatory)][string]$Exe,[string[]]$NativeArgs = @(),[switch]$AllowFail)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $Exe @NativeArgs 2>&1 | Out-String
    $rc = $LASTEXITCODE
  } finally { $ErrorActionPreference = $prev }
  if ($rc -ne 0 -and -not $AllowFail) {
    throw ($Exe + ' ' + ($NativeArgs -join ' ') + ' failed (exit ' + $rc + '):' + [Environment]::NewLine + $out)
  }
  return ,@($rc, $out)
}

Write-Step ('Ops-managed JWT secret (' + $SecretName + ' -n ' + $Namespace + ')')
$existing = Invoke-Native kubectl @('get','secret',$SecretName,'-n',$Namespace,'-o','json') -AllowFail
if ($existing[0] -eq 0) {
  $secret = $existing[1] | ConvertFrom-Json
  $requiredKeys = @('jwt-private.pem','jwt-public.pem','service-token')
  $missingKeys = @($requiredKeys | Where-Object { $null -eq $secret.data.PSObject.Properties[$_] })
  if ($missingKeys.Count -gt 0) {
    throw ('Secret/' + $SecretName + ' exists but is incomplete (missing: ' + ($missingKeys -join ', ') + '); refusing to rotate or overwrite it.')
  }
  Write-Ok 'complete secret exists -- retaining current keys and service token'
  return
}

if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
  throw 'OpenSSL is required to create the Ed25519 keypair. Install OpenSSL (Git for Windows includes it) and rerun bootstrap.'
}
if (-not $env:TEMP) { throw 'TEMP is not set; cannot create a temporary key directory.' }
if (-not $PSCmdlet.ShouldProcess(('secret/' + $SecretName + ' -n ' + $Namespace), 'create Ed25519 keys and random service token')) { return }

$tempDir = Join-Path $env:TEMP ('xenomit-api-jwt-' + [Guid]::NewGuid().ToString('N'))
$privatePath = Join-Path $tempDir 'jwt-private.pem'
$publicPath = Join-Path $tempDir 'jwt-public.pem'
$tokenPath = Join-Path $tempDir 'service-token'
$tokenBytes = New-Object byte[] 32
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try {
  $null = New-Item -ItemType Directory -Path $tempDir
  $null = Invoke-Native openssl @('genpkey','-algorithm','Ed25519','-out',$privatePath)
  $null = Invoke-Native openssl @('pkey','-in',$privatePath,'-pubout','-out',$publicPath)
  $rng.GetBytes($tokenBytes)
  $serviceToken = ([BitConverter]::ToString($tokenBytes)).Replace('-','').ToLowerInvariant()
  [System.IO.File]::WriteAllText($tokenPath,$serviceToken,[System.Text.Encoding]::ASCII)
  $null = Invoke-Native kubectl @(
    'create','secret','generic',$SecretName,'-n',$Namespace,
    ('--from-file=jwt-private.pem=' + $privatePath),
    ('--from-file=jwt-public.pem=' + $publicPath),
    ('--from-file=service-token=' + $tokenPath)
  )
  Write-Ok ('created Secret/' + $SecretName + ' with Ed25519 signing keys and a random service token')
} finally {
  $rng.Dispose()
  [Array]::Clear($tokenBytes,0,$tokenBytes.Length)
  Remove-Variable serviceToken -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
}