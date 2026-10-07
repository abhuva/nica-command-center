[CmdletBinding()]
param(
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)
$componentState = Join-Path $resolvedState "homepage"
$configDir = Join-Path $componentState "config"
$settingsPath = Join-Path $configDir "settings.local.json"
$shellBackupPath = Join-Path $configDir "settings.homepage-shell.json"
$profilePath = Join-Path $configDir "runtime-profile.json"
$manifestPath = Join-Path $componentState "homepage-process.json"

if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
  throw "Stop the migrated Homepage before restoring its shell profile."
}
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
  throw "Active Homepage settings are missing."
}
if (-not (Test-Path -LiteralPath $shellBackupPath -PathType Leaf)) {
  throw "The accepted Homepage shell backup is missing."
}
if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
  throw "The Homepage runtime profile is missing."
}

$profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
if ([string]$profile.profile -ne "homepage-project-creation") {
  throw "The project-creation profile is not active; no settings were changed."
}
$backup = Get-Content -LiteralPath $shellBackupPath -Raw | ConvertFrom-Json
$enabled = @(
  $backup.modules.psobject.Properties |
    Where-Object { [bool]$_.Value.enabled } |
    ForEach-Object { $_.Name }
)
if (Compare-Object -ReferenceObject @("bookmarks", "clock", "updo") -DifferenceObject $enabled) {
  throw "The Homepage shell backup does not contain the expected enabled modules."
}

$plan = [ordered]@{
  component = "homepage-shell"
  action = "restore-profile"
  fromProfile = "homepage-project-creation"
  toProfile = "homepage-shell"
  enabledModules = @("bookmarks", "clock", "updo")
  settingsBackup = $shellBackupPath
  productionProcessChanged = $false
}
$plan | ConvertTo-Json -Depth 4
if (-not $Apply) {
  Write-Host "Plan only. Re-run with -Apply after review."
  exit 0
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText(
  $settingsPath,
  (($backup | ConvertTo-Json -Depth 20) + [Environment]::NewLine),
  $utf8NoBom
)
$nextProfile = [ordered]@{
  version = 1
  profile = "homepage-shell"
  enabledModules = @("bookmarks", "clock", "updo")
  restoredAt = (Get-Date).ToString("o")
}
[System.IO.File]::WriteAllText(
  $profilePath,
  (($nextProfile | ConvertTo-Json -Depth 6) + [Environment]::NewLine),
  $utf8NoBom
)

$nextProfile | ConvertTo-Json -Depth 4
