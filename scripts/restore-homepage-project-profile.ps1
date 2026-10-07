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
$projectBackupPath = Join-Path $configDir "settings.homepage-project-creation.json"
$profilePath = Join-Path $configDir "runtime-profile.json"
$manifestPath = Join-Path $componentState "homepage-process.json"

if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
  throw "Stop the migrated Homepage before restoring its project-creation profile."
}
foreach ($requiredPath in @($settingsPath, $projectBackupPath, $profilePath)) {
  if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    throw "Required Homepage profile file is missing; no settings were changed."
  }
}

$profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
if ([string]$profile.profile -ne "homepage-project-beantime") {
  throw "The Beantime profile is not active; no settings were changed."
}
$activeSettings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
$timerStateSetting = [string]$activeSettings.modules.beantime.stateFile
if ([string]::IsNullOrWhiteSpace($timerStateSetting) -or [System.IO.Path]::IsPathRooted($timerStateSetting)) {
  throw "Active Beantime timer-state configuration is invalid; no settings were changed."
}
$timerStatePath = [System.IO.Path]::GetFullPath((Join-Path $componentState $timerStateSetting))
$componentPrefix = $componentState.TrimEnd('\') + '\'
if (-not $timerStatePath.StartsWith($componentPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "Active Beantime timer-state configuration escapes local state; no settings were changed."
}
if (Test-Path -LiteralPath $timerStatePath -PathType Leaf) {
  try {
    $timerState = Get-Content -LiteralPath $timerStatePath -Raw | ConvertFrom-Json
  } catch {
    throw "Active Beantime timer state is invalid JSON; no settings were changed."
  }
  if (
    -not [string]::IsNullOrWhiteSpace([string]$timerState.startedAt) -and
    -not [string]::IsNullOrWhiteSpace([string]$timerState.account)
  ) {
    throw "A migrated Beantime timer is still active; stop it before restoring the project profile."
  }
}
$backup = Get-Content -LiteralPath $projectBackupPath -Raw | ConvertFrom-Json
$enabled = @(
  $backup.modules.psobject.Properties |
    Where-Object { [bool]$_.Value.enabled } |
    ForEach-Object { $_.Name }
)
if (Compare-Object -ReferenceObject @("bookmarks", "clock", "newProject", "updo") -DifferenceObject $enabled) {
  throw "The project-creation backup does not contain the expected enabled modules."
}

$plan = [ordered]@{
  component = "homepage-shell"
  action = "restore-profile"
  fromProfile = "homepage-project-beantime"
  toProfile = "homepage-project-creation"
  enabledModules = @("bookmarks", "clock", "newProject", "updo")
  settingsBackup = $projectBackupPath
  ledgerChanged = $false
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
  profile = "homepage-project-creation"
  enabledModules = @("bookmarks", "clock", "newProject", "updo")
  writeCapabilities = @("project.create")
  restoredAt = (Get-Date).ToString("o")
}
[System.IO.File]::WriteAllText(
  $profilePath,
  (($nextProfile | ConvertTo-Json -Depth 6) + [Environment]::NewLine),
  $utf8NoBom
)

$nextProfile | ConvertTo-Json -Depth 4
