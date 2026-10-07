[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$VaultRoot,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\candidate"),
  [switch]$Apply,
  [switch]$WriteEnabled,
  [int]$CalendarPort = 4273,
  [int]$HomepagePort = 4274,
  [int]$VaultGraphPort = 4275,
  [int]$EmailPort = 4276,
  [int]$FavaPort = 4464
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedVault = (Resolve-Path -LiteralPath $VaultRoot).Path
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)

$vaultPrefix = $resolvedVault.TrimEnd('\') + '\'
$statePrefix = $resolvedState.TrimEnd('\') + '\'
if ($resolvedVault -eq $resolvedState -or $resolvedState.StartsWith($vaultPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or $resolvedVault.StartsWith($statePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "VaultRoot and StateRoot must be separate directory trees."
}
$ports = @($CalendarPort, $HomepagePort, $VaultGraphPort, $EmailPort, $FavaPort)
if (($ports | Select-Object -Unique).Count -ne $ports.Count) { throw "Candidate ports must be unique." }

$plan = [ordered]@{
  repository = $repoRoot
  vaultAuthority = $resolvedVault
  localState = $resolvedState
  mode = if ($WriteEnabled) { "read-write" } else { "read-only" }
  ports = [ordered]@{ calendar = $CalendarPort; homepage = $HomepagePort; vaultGraph = $VaultGraphPort; email = $EmailPort; fava = $FavaPort }
  productionLaunchersChanged = $false
}
$plan | ConvertTo-Json -Depth 4
if (-not $Apply) {
  Write-Host "Plan only. Re-run with -Apply to build derived data and start the candidate."
  exit 0
}

New-Item -ItemType Directory -Force -Path $resolvedState | Out-Null
$resolvedState = (Resolve-Path -LiteralPath $resolvedState).Path

$env:NICA_VAULT_ROOT = $resolvedVault
$env:NICA_STATE_ROOT = $resolvedState
$env:NICA_WRITE_ENABLED = if ($WriteEnabled) { "true" } else { "false" }
$env:CALENDAR_PORT = [string]$CalendarPort
$env:HOMEPAGE_PORT = [string]$HomepagePort
$env:VAULTGRAPH_PORT = [string]$VaultGraphPort
$env:EMAIL_PORT = [string]$EmailPort
$env:BEANTIME_FAVA_PORT = [string]$FavaPort
$env:NICA_HOMEPAGE_URL = "http://127.0.0.1:$HomepagePort"
$env:VAULTGRAPH_URL = "http://127.0.0.1:$VaultGraphPort/vault-graph.html"
$env:EMAIL_URL = "http://127.0.0.1:$EmailPort/email.html"

& node (Join-Path $repoRoot "scripts\doctor.mjs")
if ($LASTEXITCODE -ne 0) { throw "Candidate doctor failed." }
& node (Join-Path $repoRoot "Calendar\build-events.mjs")
if ($LASTEXITCODE -ne 0) { throw "Calendar derived-data build failed." }
& node (Join-Path $repoRoot "VaultGraph\build-graph.mjs")
if ($LASTEXITCODE -ne 0) { throw "VaultGraph derived-data build failed." }

$logDir = Join-Path $resolvedState "launcher"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$processes = @(
  @{ name = "homepage"; file = "node"; args = ('"' + (Join-Path $repoRoot "serve.mjs") + '"'); cwd = $repoRoot },
  @{ name = "calendar"; file = "node"; args = ('"' + (Join-Path $repoRoot "Calendar\serve.mjs") + '"'); cwd = (Join-Path $repoRoot "Calendar") },
  @{ name = "vaultgraph"; file = "node"; args = ('"' + (Join-Path $repoRoot "VaultGraph\serve.mjs") + '"'); cwd = (Join-Path $repoRoot "VaultGraph") },
  @{ name = "email"; file = "python"; args = ('"' + (Join-Path $repoRoot "Email\email_tool.py") + '" serve'); cwd = (Join-Path $repoRoot "Email") }
)
$started = foreach ($item in $processes) {
  $stdout = Join-Path $logDir ($item.name + ".out.log")
  $stderr = Join-Path $logDir ($item.name + ".err.log")
  $proc = Start-Process -FilePath $item.file -ArgumentList $item.args -WorkingDirectory $item.cwd -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
  [ordered]@{ name = $item.name; pid = $proc.Id; stdout = $stdout; stderr = $stderr }
}
$manifest = [ordered]@{ repository = $repoRoot; startedAt = (Get-Date).ToString("o"); processes = @($started) }
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $logDir "processes.json") -Encoding utf8
$healthChecks = @(
  @{ name = "homepage"; url = "http://127.0.0.1:$HomepagePort/api/ping" },
  @{ name = "calendar"; url = "http://127.0.0.1:$CalendarPort/api/ping" },
  @{ name = "vaultgraph"; url = "http://127.0.0.1:$VaultGraphPort/api/ping" },
  @{ name = "email"; url = "http://127.0.0.1:$EmailPort/api/ping" }
)
try {
  foreach ($check in $healthChecks) {
    $healthy = $false
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
      try {
        $response = Invoke-RestMethod -Uri $check.url -TimeoutSec 1
        $expectedMode = if ($WriteEnabled) { "read-write" } else { "read-only" }
        if ($response.ok -and [bool]$response.writesEnabled -eq [bool]$WriteEnabled -and $response.mode -eq $expectedMode) { $healthy = $true; break }
      } catch { }
      Start-Sleep -Milliseconds 250
    }
    if (-not $healthy) { throw "$($check.name) did not become healthy in read-only mode." }
  }
} catch {
  foreach ($entry in $started) { Stop-Process -Id $entry.pid -ErrorAction SilentlyContinue }
  throw
}
$manifest | ConvertTo-Json -Depth 4
