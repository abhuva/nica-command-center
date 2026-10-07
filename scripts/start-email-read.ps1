[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$VaultRoot,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [string]$LegacyToolsRoot = "",
  [int]$Port = 4276,
  [switch]$RefreshSnapshot,
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedVault = (Resolve-Path -LiteralPath $VaultRoot).Path
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)
$legacyRootInput = if ([string]::IsNullOrWhiteSpace($LegacyToolsRoot)) {
  Join-Path $resolvedVault "Tools"
} else {
  $LegacyToolsRoot
}
$resolvedLegacy = (Resolve-Path -LiteralPath $legacyRootInput).Path
$sourceDatabase = Join-Path $resolvedLegacy "Email\email.db"
if (-not (Test-Path -LiteralPath $sourceDatabase -PathType Leaf)) {
  throw "Legacy Email database was not found."
}

$vaultPrefix = $resolvedVault.TrimEnd('\') + '\'
$statePrefix = $resolvedState.TrimEnd('\') + '\'
if (
  $resolvedVault -eq $resolvedState -or
  $resolvedState.StartsWith($vaultPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
  $resolvedVault.StartsWith($statePrefix, [System.StringComparison]::OrdinalIgnoreCase)
) {
  throw "VaultRoot and StateRoot must be separate directory trees."
}
if ($Port -lt 1 -or $Port -gt 65535) { throw "Port must be between 1 and 65535." }

$componentState = Join-Path $resolvedState "email"
$candidateDatabase = Join-Path $componentState "email.db"
$sourceInfo = Get-Item -LiteralPath $sourceDatabase
$plan = [ordered]@{
  component = "email-read-shadow"
  repository = $repoRoot
  vaultAuthority = $resolvedVault
  localState = $componentState
  sourceDatabaseBytes = $sourceInfo.Length
  sourceWalPresent = Test-Path -LiteralPath ($sourceDatabase + "-wal") -PathType Leaf
  sourceShmPresent = Test-Path -LiteralPath ($sourceDatabase + "-shm") -PathType Leaf
  snapshotAction = if ($RefreshSnapshot) { "consistent-sqlite-backup" } else { "retain-existing" }
  snapshotReady = Test-Path -LiteralPath $candidateDatabase -PathType Leaf
  credentialsCopied = $false
  oauthTokensCopied = $false
  mailFetchEnabled = $false
  vaultExportEnabled = $false
  port = $Port
  mode = "read-only"
  productionProcessChanged = $false
}
$plan | ConvertTo-Json -Depth 3
if (-not $Apply) {
  Write-Host "Plan only. Re-run with -Apply after reviewing the snapshot source, authority, state root, and port."
  exit 0
}

$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($listener) { throw "Port $Port is already in use; no process was stopped." }

New-Item -ItemType Directory -Force -Path $componentState | Out-Null
$componentState = (Resolve-Path -LiteralPath $componentState).Path
$candidateDatabase = Join-Path $componentState "email.db"
if ($RefreshSnapshot) {
  & python (Join-Path $repoRoot "Email\snapshot_db.py") --source $sourceDatabase --destination $candidateDatabase
  if ($LASTEXITCODE -ne 0) { throw "Consistent Email database snapshot failed." }
}
if (-not (Test-Path -LiteralPath $candidateDatabase -PathType Leaf)) {
  throw "Email snapshot is not initialized. Re-run with -RefreshSnapshot -Apply."
}

$env:NICA_VAULT_ROOT = $resolvedVault
$env:NICA_STATE_ROOT = $resolvedState
$env:NICA_WRITE_ENABLED = "false"
$env:EMAIL_HOST = "127.0.0.1"
$env:EMAIL_PORT = [string]$Port
$env:MS_CLIENT_ID = ""
$env:MS_CLIENT_SECRET = ""
$env:GOOGLE_CLIENT_ID = ""
$env:GOOGLE_CLIENT_SECRET = ""

$stdout = Join-Path $componentState "email-read.out.log"
$stderr = Join-Path $componentState "email-read.err.log"
$serverPath = Join-Path $repoRoot "Email\email_tool.py"
$proc = Start-Process -FilePath "python" -ArgumentList ('"' + $serverPath + '" serve') -WorkingDirectory (Join-Path $repoRoot "Email") -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
$manifestPath = Join-Path $componentState "email-read-process.json"
$manifest = [ordered]@{
  component = "email-read-shadow"
  repository = $repoRoot
  vaultAuthority = $resolvedVault
  stateRoot = $resolvedState
  port = $Port
  mode = "read-only"
  snapshotRefreshed = [bool]$RefreshSnapshot
  pid = $proc.Id
  startedAt = (Get-Date).ToString("o")
  stdout = $stdout
  stderr = $stderr
}
$manifest | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $manifestPath -Encoding utf8

try {
  $healthy = $false
  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    try {
      $response = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/ping" -TimeoutSec 1
      if (
        $response.ok -and
        $response.component -eq "email" -and
        $response.mode -eq "read-only" -and
        -not [bool]$response.writesEnabled -and
        $response.authority.vault -eq $resolvedVault -and
        $response.authority.localState -eq $componentState
      ) {
        $healthy = $true
        break
      }
    } catch { }
    Start-Sleep -Milliseconds 250
  }
  if (-not $healthy) { throw "Email shadow did not become healthy with the planned authority and mode." }

  try {
    Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/fetch" -Method Post -ContentType "application/json" -Body "{}" -UseBasicParsing | Out-Null
    throw "Email fetch route unexpectedly accepted a read-only request."
  } catch {
    if ([int]$_.Exception.Response.StatusCode -ne 403) { throw }
  }
} catch {
  Stop-Process -Id $proc.Id -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $componentState "email.preview.pid") -Force -ErrorAction SilentlyContinue
  throw
}

$manifest | ConvertTo-Json -Depth 3
