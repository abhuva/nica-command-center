[CmdletBinding()]
param(
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [int]$Port = 4274,
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)
$componentState = Join-Path $resolvedState "homepage"
$configDir = Join-Path $componentState "config"
$settingsPath = Join-Path $configDir "settings.local.json"
$backupPath = Join-Path $configDir "settings.monitoring-only.json"
$profilePath = Join-Path $configDir "runtime-profile.json"
$homepageManifestPath = Join-Path $componentState "homepage-process.json"
$monitoringManifestPath = Join-Path $componentState "monitoring-process.json"

$backupReady = Test-Path -LiteralPath $backupPath -PathType Leaf
$plan = [ordered]@{
  component = "homepage-shell"
  operation = "restore-monitoring-only-profile"
  localState = $componentState
  port = $Port
  backupReady = $backupReady
  processManifestsPresent = [bool](
    (Test-Path -LiteralPath $homepageManifestPath -PathType Leaf) -or
    (Test-Path -LiteralPath $monitoringManifestPath -PathType Leaf)
  )
}
$plan | ConvertTo-Json -Depth 3
if (-not $Apply) {
  Write-Host "Plan only. Stop the Homepage shell, then re-run with -Apply."
  exit 0
}

if (-not $backupReady) { throw "Monitoring-only profile backup is missing." }
if (
  (Test-Path -LiteralPath $homepageManifestPath -PathType Leaf) -or
  (Test-Path -LiteralPath $monitoringManifestPath -PathType Leaf)
) {
  throw "A Homepage-related process manifest is present; stop that process first."
}
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
  throw "Port $Port is occupied; no profile was changed."
}

$backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
$enabled = @(
  $backup.modules.psobject.Properties |
    Where-Object { [bool]$_.Value.enabled } |
    ForEach-Object { $_.Name }
)
if (@($enabled).Count -ne 1 -or $enabled[0] -ne "updo" -or -not @($backup.modules.updo.targets).Count) {
  throw "Monitoring-only profile backup is invalid."
}

Copy-Item -LiteralPath $backupPath -Destination $settingsPath -Force
Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
Write-Host "Monitoring-only profile restored. Start it with start-monitoring.ps1."
