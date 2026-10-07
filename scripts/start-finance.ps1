[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidateSet("nica", "tohu")][string]$FinanceId,
  [Parameter(Mandatory = $true)][string]$VaultRoot,
  [Parameter(Mandatory = $true)][string]$LedgerRelativePath,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [Parameter(Mandatory = $true)][int]$Port,
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedVault = (Resolve-Path -LiteralPath $VaultRoot).Path
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)
if ([System.IO.Path]::IsPathRooted($LedgerRelativePath)) {
  throw "Finance ledger path must be relative to the configured vault root."
}
$vaultPrefix = $resolvedVault.TrimEnd('\') + '\'
$ledgerCandidate = [System.IO.Path]::GetFullPath((Join-Path $resolvedVault $LedgerRelativePath))
if (-not $ledgerCandidate.StartsWith($vaultPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "Finance ledger path escapes the configured vault root."
}
$ledgerPath = (Resolve-Path -LiteralPath $ledgerCandidate).Path
if ($Port -lt 1 -or $Port -gt 65535) { throw "Port must be between 1 and 65535." }
$componentState = Join-Path $resolvedState "finance\$FinanceId"
$manifestPath = Join-Path $componentState "finance-process.json"
$plan = [ordered]@{
  component = "finance-$FinanceId"
  repository = $repoRoot
  vaultAuthority = $resolvedVault
  ledger = $LedgerRelativePath.Replace('\', '/')
  localState = $componentState
  port = $Port
  ledgerWrites = $false
}
$plan | ConvertTo-Json -Depth 4
if (-not $Apply) {
  Write-Host "Plan only. Re-run with -Apply after reviewing the ledger and port."
  return
}
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
  throw "Finance process manifest already exists; use stop-finance.ps1 first."
}
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
  throw "Finance port $Port is already in use; no process was stopped."
}
$fava = Get-Command fava -ErrorAction Stop
New-Item -ItemType Directory -Force -Path $componentState | Out-Null
$stdout = Join-Path $componentState "finance.out.log"
$stderr = Join-Path $componentState "finance.err.log"
$arguments = '"' + (Split-Path -Leaf $ledgerPath) + '" --host 127.0.0.1 --port ' + $Port
$proc = $null
try {
  $proc = Start-Process -FilePath $fava.Source -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $ledgerPath) -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
  $manifest = [ordered]@{
    component = "finance-$FinanceId"
    repository = $repoRoot
    vaultAuthority = $resolvedVault
    ledger = $LedgerRelativePath.Replace('\', '/')
    stateRoot = $resolvedState
    port = $Port
    pid = $proc.Id
    startedAt = (Get-Date).ToString("o")
    stdout = $stdout
    stderr = $stderr
  }
  $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding utf8
  $healthy = $false
  for ($attempt = 0; $attempt -lt 40; $attempt += 1) {
    try {
      $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/" -TimeoutSec 1
      if ([int]$response.StatusCode -eq 200) { $healthy = $true; break }
    } catch { }
    Start-Sleep -Milliseconds 250
  }
  if (-not $healthy) { throw "Finance service $FinanceId did not become healthy." }
} catch {
  if ($proc) { Stop-Process -Id $proc.Id -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
  throw
}
$manifest | ConvertTo-Json -Depth 4
