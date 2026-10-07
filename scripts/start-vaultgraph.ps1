[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$VaultRoot,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [int]$Port = 4175,
  [switch]$EnableRebuild,
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedVault = (Resolve-Path -LiteralPath $VaultRoot).Path
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)

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

$plan = [ordered]@{
  component = "vaultgraph"
  repository = $repoRoot
  vaultAuthority = $resolvedVault
  localState = $resolvedState
  mode = if ($EnableRebuild) { "read-write-derived-state" } else { "read-only" }
  port = $Port
  vaultWrites = $false
  credentialsRequired = $false
  productionLauncherChanged = $false
}
$plan | ConvertTo-Json -Depth 3
if (-not $Apply) {
  Write-Host "Plan only. Re-run with -Apply after reviewing the authority, state root, mode, and port."
  exit 0
}

$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($listener) { throw "Port $Port is already in use; no process was stopped." }

New-Item -ItemType Directory -Force -Path $resolvedState | Out-Null
$resolvedState = (Resolve-Path -LiteralPath $resolvedState).Path
$componentState = Join-Path $resolvedState "vaultgraph"
New-Item -ItemType Directory -Force -Path $componentState | Out-Null
$componentState = (Resolve-Path -LiteralPath $componentState).Path

$env:NICA_VAULT_ROOT = $resolvedVault
$env:NICA_STATE_ROOT = $resolvedState
$env:NICA_WRITE_ENABLED = if ($EnableRebuild) { "true" } else { "false" }
$env:VAULTGRAPH_PORT = [string]$Port

& node (Join-Path $repoRoot "VaultGraph\build-graph.mjs")
if ($LASTEXITCODE -ne 0) { throw "VaultGraph derived-data build failed." }

$stdout = Join-Path $componentState "vaultgraph.out.log"
$stderr = Join-Path $componentState "vaultgraph.err.log"
$serverPath = Join-Path $repoRoot "VaultGraph\serve.mjs"
$proc = Start-Process -FilePath "node" -ArgumentList ('"' + $serverPath + '"') -WorkingDirectory (Join-Path $repoRoot "VaultGraph") -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
$manifestPath = Join-Path $componentState "cutover-process.json"
$manifest = [ordered]@{
  component = "vaultgraph"
  repository = $repoRoot
  vaultAuthority = $resolvedVault
  stateRoot = $resolvedState
  port = $Port
  mode = if ($EnableRebuild) { "read-write" } else { "read-only" }
  pid = $proc.Id
  startedAt = (Get-Date).ToString("o")
  stdout = $stdout
  stderr = $stderr
}
$manifest | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $manifestPath -Encoding utf8

try {
  $healthy = $false
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    try {
      $response = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/ping" -TimeoutSec 1
      $expectedMode = if ($EnableRebuild) { "read-write" } else { "read-only" }
      if (
        $response.ok -and
        $response.component -eq "vaultgraph" -and
        $response.mode -eq $expectedMode -and
        [bool]$response.writesEnabled -eq [bool]$EnableRebuild -and
        $response.authority.vault -eq $resolvedVault -and
        $response.authority.localState -eq $componentState
      ) {
        $healthy = $true
        break
      }
    } catch { }
    Start-Sleep -Milliseconds 250
  }
  if (-not $healthy) { throw "VaultGraph did not become healthy with the planned authority and mode." }
} catch {
  Stop-Process -Id $proc.Id -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
  throw
}

$manifest | ConvertTo-Json -Depth 3
