$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("nica-homepage-beantime-profile-" + [Guid]::NewGuid().ToString("N"))
$stateRoot = Join-Path $sandbox "state"
$componentState = Join-Path $stateRoot "homepage"
$configDir = Join-Path $componentState "config"
$settingsPath = Join-Path $configDir "settings.local.json"
$backupPath = Join-Path $configDir "settings.homepage-project-creation.json"
$profilePath = Join-Path $configDir "runtime-profile.json"
$timerStatePath = Join-Path $componentState "beantime\state.json"
$restoreScript = Join-Path $repoRoot "scripts\restore-homepage-project-profile.ps1"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-TestJson {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  [System.IO.File]::WriteAllText(
    $Path,
    (($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine),
    $utf8NoBom
  )
}

function Get-EnabledModules {
  param([Parameter(Mandatory = $true)]$Settings)
  return @(
    $Settings.modules.psobject.Properties |
      Where-Object { [bool]$_.Value.enabled } |
      ForEach-Object { $_.Name }
  )
}

$projectSettings = [ordered]@{
  schemaVersion = 1
  modules = [ordered]@{
    bookmarks = [ordered]@{ enabled = $true }
    clock = [ordered]@{ enabled = $true }
    newProject = [ordered]@{ enabled = $true }
    beantime = [ordered]@{ enabled = $false }
    vaultGraph = [ordered]@{ enabled = $false }
    email = [ordered]@{ enabled = $false }
    updo = [ordered]@{ enabled = $true }
  }
}
$beantimeSettings = $projectSettings | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$beantimeSettings.modules.beantime = [pscustomobject][ordered]@{
  enabled = $true
  stateFile = "beantime/state.json"
}
$beantimeProfile = [ordered]@{
  version = 1
  profile = "homepage-project-beantime"
  enabledModules = @("bookmarks", "clock", "newProject", "beantime", "updo")
  writeCapabilities = @(
    "project.create",
    "beantime.read",
    "beantime.timer",
    "beantime.append",
    "beantime.fava"
  )
  beantimeLedgerAuthority = "vault"
  beantimeLedgerPath = "Tools/data/beantime/zeit.beancount"
}

try {
  Write-TestJson -Path $settingsPath -Value $beantimeSettings
  Write-TestJson -Path $backupPath -Value $projectSettings
  Write-TestJson -Path $profilePath -Value $beantimeProfile
  Write-TestJson -Path $timerStatePath -Value ([ordered]@{
    startedAt = "2031-01-01T12:00:00.000Z"
    startedDate = "2031-01-01"
    account = "Projekte:Synthetic"
    personAccount = "Zeit:Example"
    summary = "Synthetic active timer"
  })

  $blocked = $false
  try {
    & $restoreScript -StateRoot $stateRoot -Apply | Out-Null
  } catch {
    $blocked = $_.Exception.Message -match "timer is still active"
  }
  if (-not $blocked) { throw "Rollback did not reject an active synthetic timer." }
  $stillActiveProfile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
  if ([string]$stillActiveProfile.profile -ne "homepage-project-beantime") {
    throw "Rejected rollback changed the active profile."
  }

  Remove-Item -LiteralPath $timerStatePath -Force
  & $restoreScript -StateRoot $stateRoot | Out-Null
  $planOnlyProfile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
  if ([string]$planOnlyProfile.profile -ne "homepage-project-beantime") {
    throw "Rollback plan changed the active profile."
  }

  & $restoreScript -StateRoot $stateRoot -Apply | Out-Null
  $restoredProfile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
  if ([string]$restoredProfile.profile -ne "homepage-project-creation") {
    throw "Rollback did not restore the project-creation profile."
  }
  $restoredSettings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
  $expectedModules = @("bookmarks", "clock", "newProject", "updo")
  if (Compare-Object -ReferenceObject $expectedModules -DifferenceObject (Get-EnabledModules -Settings $restoredSettings)) {
    throw "Rollback restored unexpected enabled modules."
  }
  if ([bool]$restoredSettings.modules.beantime.enabled) {
    throw "Rollback left Beantime enabled."
  }

  Write-Output "Homepage Beantime profile rollback smoke check OK"
} finally {
  if (Test-Path -LiteralPath $sandbox) {
    $resolvedSandbox = [System.IO.Path]::GetFullPath($sandbox)
    $tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedSandbox.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Synthetic test sandbox escaped the system temporary directory."
    }
    Remove-Item -LiteralPath $resolvedSandbox -Recurse -Force
  }
}
