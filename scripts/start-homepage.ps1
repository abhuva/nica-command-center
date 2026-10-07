[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$VaultRoot,
  [Parameter(Mandatory = $true)][string]$ObsidianVaultName,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [string]$LegacyToolsRoot = "",
  [int]$Port = 4274,
  [int]$LegacyHomepagePort = 4174,
  [int]$BeantimeFavaPort = 3464,
  [switch]$PrepareShellProfile,
  [switch]$PrepareProjectProfile,
  [switch]$PrepareBeantimeProfile,
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
if ($LegacyHomepagePort -lt 1 -or $LegacyHomepagePort -gt 65535) {
  throw "LegacyHomepagePort must be between 1 and 65535."
}
if ($BeantimeFavaPort -lt 1 -or $BeantimeFavaPort -gt 65535) {
  throw "BeantimeFavaPort must be between 1 and 65535."
}
$homepagePorts = @($Port, $LegacyHomepagePort, $BeantimeFavaPort)
if (($homepagePorts | Select-Object -Unique).Count -ne 3) {
  throw "Port, LegacyHomepagePort, and BeantimeFavaPort must be different."
}
if ([string]::IsNullOrWhiteSpace($ObsidianVaultName)) {
  throw "ObsidianVaultName is required for explicit Obsidian CLI reads."
}
$prepareCount = [int][bool]$PrepareShellProfile + [int][bool]$PrepareProjectProfile + [int][bool]$PrepareBeantimeProfile
if ($prepareCount -gt 1) {
  throw "PrepareShellProfile, PrepareProjectProfile, and PrepareBeantimeProfile are mutually exclusive."
}

$componentState = Join-Path $resolvedState "homepage"
$configDir = Join-Path $componentState "config"
$settingsPath = Join-Path $configDir "settings.local.json"
$monitoringBackupPath = Join-Path $configDir "settings.monitoring-only.json"
$shellBackupPath = Join-Path $configDir "settings.homepage-shell.json"
$projectBackupPath = Join-Path $configDir "settings.homepage-project-creation.json"
$profilePath = Join-Path $configDir "runtime-profile.json"
$homepageManifestPath = Join-Path $componentState "homepage-process.json"
$monitoringManifestPath = Join-Path $componentState "monitoring-process.json"
$legacyRootInput = if ([string]::IsNullOrWhiteSpace($LegacyToolsRoot)) {
  Join-Path $resolvedVault "Tools"
} else {
  $LegacyToolsRoot
}
$resolvedLegacy = $null
$legacySettingsPath = $null
if ($PrepareShellProfile -or $PrepareProjectProfile -or $PrepareBeantimeProfile) {
  $resolvedLegacy = (Resolve-Path -LiteralPath $legacyRootInput).Path
  $legacySettingsPath = Join-Path $resolvedLegacy "config\settings.local.json"
  if (-not (Test-Path -LiteralPath $legacySettingsPath -PathType Leaf)) {
    throw "Legacy Homepage settings were not found."
  }
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText(
    $Path,
    (($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine),
    $utf8NoBom
  )
}

function Get-CurrentProfile {
  if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) { return "monitoring-only" }
  try {
    $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    return [string]$profile.profile
  } catch {
    return "invalid"
  }
}

function Prepare-HomepageShellProfile {
  if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "Accepted monitoring settings are missing; initialize monitoring first."
  }

  $current = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
  $legacy = Get-Content -LiteralPath $legacySettingsPath -Raw | ConvertFrom-Json
  if (-not [bool]$current.modules.updo.enabled -or -not @($current.modules.updo.targets).Count) {
    throw "Accepted monitoring configuration is unavailable."
  }

  if (Test-Path -LiteralPath $monitoringBackupPath -PathType Leaf) {
    $currentCanonical = $current | ConvertTo-Json -Depth 20 -Compress
    $backup = Get-Content -LiteralPath $monitoringBackupPath -Raw | ConvertFrom-Json
    $backupCanonical = $backup | ConvertTo-Json -Depth 20 -Compress
    if ($currentCanonical -ne $backupCanonical) {
      throw "The monitoring-only backup differs from the active settings; profile preparation will not overwrite it."
    }
  }

  $shellSettings = [ordered]@{
    schemaVersion = 1
    ui = [ordered]@{
      title = [string]$legacy.ui.title
      titleSize = $legacy.ui.titleSize
      search = [ordered]@{
        provider = [string]$legacy.ui.search.provider
        openInNewTab = [bool]$legacy.ui.search.openInNewTab
      }
      theme = [ordered]@{
        mode = [string]$legacy.ui.theme.mode
        preset = [string]$legacy.ui.theme.preset
        shape = [string]$legacy.ui.theme.shape
      }
    }
    modules = [ordered]@{
      bookmarks = [ordered]@{
        enabled = $true
        title = [string]$legacy.modules.bookmarks.title
        showPath = [bool]$legacy.modules.bookmarks.showPath
        showType = [bool]$legacy.modules.bookmarks.showType
        openInNewTab = [bool]$legacy.modules.bookmarks.openInNewTab
        cardMaxWidth = $legacy.modules.bookmarks.cardMaxWidth
      }
      clock = [ordered]@{
        enabled = $true
        title = [string]$legacy.modules.clock.title
        showSeconds = [bool]$legacy.modules.clock.showSeconds
        hour12 = [bool]$legacy.modules.clock.hour12
      }
      newProject = [ordered]@{ enabled = $false }
      beantime = [ordered]@{ enabled = $false }
      vaultGraph = [ordered]@{ enabled = $false }
      email = [ordered]@{ enabled = $false }
      updo = $current.modules.updo
    }
  }

  if (-not (Test-Path -LiteralPath $monitoringBackupPath -PathType Leaf)) {
    Copy-Item -LiteralPath $settingsPath -Destination $monitoringBackupPath
  }
  try {
    Write-JsonFile -Path $settingsPath -Value $shellSettings
    Write-JsonFile -Path $profilePath -Value ([ordered]@{
      version = 1
      profile = "homepage-shell"
      enabledModules = @("bookmarks", "clock", "updo")
      preparedAt = (Get-Date).ToString("o")
    })
  } catch {
    Copy-Item -LiteralPath $monitoringBackupPath -Destination $settingsPath -Force
    Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
    throw
  }
}

function Prepare-ProjectCreationProfile {
  if ((Get-CurrentProfile) -ne "homepage-shell") {
    throw "The accepted Homepage shell profile must be active before project creation is enabled."
  }
  if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "Accepted Homepage shell settings are missing."
  }

  $current = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
  $legacy = Get-Content -LiteralPath $legacySettingsPath -Raw | ConvertFrom-Json
  $currentEnabled = @(
    $current.modules.psobject.Properties |
      Where-Object { [bool]$_.Value.enabled } |
      ForEach-Object { $_.Name }
  )
  if (Compare-Object -ReferenceObject @("bookmarks", "clock", "updo") -DifferenceObject $currentEnabled) {
    throw "The active settings do not match the accepted Homepage shell profile."
  }

  if (Test-Path -LiteralPath $shellBackupPath -PathType Leaf) {
    $currentCanonical = $current | ConvertTo-Json -Depth 20 -Compress
    $backup = Get-Content -LiteralPath $shellBackupPath -Raw | ConvertFrom-Json
    $backupCanonical = $backup | ConvertTo-Json -Depth 20 -Compress
    if ($currentCanonical -ne $backupCanonical) {
      throw "The Homepage shell backup differs from the active settings; project profile preparation will not overwrite it."
    }
  }

  $current.modules.newProject = [pscustomobject][ordered]@{
    enabled = $true
    title = [string]$legacy.modules.newProject.title
    openInNewTab = [bool]$legacy.modules.newProject.openInNewTab
  }
  if (-not (Test-Path -LiteralPath $shellBackupPath -PathType Leaf)) {
    Copy-Item -LiteralPath $settingsPath -Destination $shellBackupPath
  }
  try {
    Write-JsonFile -Path $settingsPath -Value $current
    Write-JsonFile -Path $profilePath -Value ([ordered]@{
      version = 1
      profile = "homepage-project-creation"
      enabledModules = @("bookmarks", "clock", "newProject", "updo")
      writeCapabilities = @("project.create")
      preparedAt = (Get-Date).ToString("o")
    })
  } catch {
    Copy-Item -LiteralPath $shellBackupPath -Destination $settingsPath -Force
    Write-JsonFile -Path $profilePath -Value ([ordered]@{
      version = 1
      profile = "homepage-shell"
      enabledModules = @("bookmarks", "clock", "updo")
      preparedAt = (Get-Date).ToString("o")
    })
    throw
  }
}

function Prepare-BeantimeProfile {
  if ((Get-CurrentProfile) -ne "homepage-project-creation") {
    throw "The accepted project-creation profile must be active before Beantime is enabled."
  }
  if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "Accepted Homepage settings are missing."
  }

  $current = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
  $legacy = Get-Content -LiteralPath $legacySettingsPath -Raw | ConvertFrom-Json
  $currentEnabled = @(
    $current.modules.psobject.Properties |
      Where-Object { [bool]$_.Value.enabled } |
      ForEach-Object { $_.Name }
  )
  if (Compare-Object -ReferenceObject @("bookmarks", "clock", "newProject", "updo") -DifferenceObject $currentEnabled) {
    throw "The active settings do not match the accepted project-creation profile."
  }
  if (-not [bool]$legacy.modules.beantime.enabled) {
    throw "Legacy Beantime is not enabled; its configuration was not imported."
  }

  $legacyLedgerSetting = [string]$legacy.modules.beantime.file
  if ([string]::IsNullOrWhiteSpace($legacyLedgerSetting) -or [System.IO.Path]::IsPathRooted($legacyLedgerSetting)) {
    throw "Legacy Beantime ledger configuration must be relative to the legacy Tools root."
  }
  $ledgerCandidate = [System.IO.Path]::GetFullPath((Join-Path $resolvedLegacy $legacyLedgerSetting))
  $legacyPrefix = $resolvedLegacy.TrimEnd('\') + '\'
  if (-not $ledgerCandidate.StartsWith($legacyPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Legacy Beantime ledger configuration escapes the legacy Tools root."
  }
  $resolvedLedger = (Resolve-Path -LiteralPath $ledgerCandidate).Path
  if (-not (Test-Path -LiteralPath $resolvedLedger -PathType Leaf)) {
    throw "Legacy Beantime ledger was not found."
  }
  if (-not $resolvedLedger.StartsWith($vaultPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Beantime ledger must remain inside the configured Nextcloud vault."
  }
  $ledgerRelativeToVault = $resolvedLedger.Substring($vaultPrefix.Length).Replace('\', '/')

  $legacyStateSetting = [string]$legacy.modules.beantime.stateFile
  if (-not [string]::IsNullOrWhiteSpace($legacyStateSetting)) {
    if ([System.IO.Path]::IsPathRooted($legacyStateSetting)) {
      throw "Legacy Beantime timer-state configuration must be relative."
    }
    $legacyStateCandidate = [System.IO.Path]::GetFullPath((Join-Path $resolvedLegacy $legacyStateSetting))
    if (-not $legacyStateCandidate.StartsWith($legacyPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Legacy Beantime timer-state configuration escapes the legacy Tools root."
    }
    if (Test-Path -LiteralPath $legacyStateCandidate -PathType Leaf) {
      try {
        $legacyState = Get-Content -LiteralPath $legacyStateCandidate -Raw | ConvertFrom-Json
      } catch {
        throw "Legacy Beantime timer state is invalid JSON; no profile was changed."
      }
      if (
        -not [string]::IsNullOrWhiteSpace([string]$legacyState.startedAt) -and
        -not [string]::IsNullOrWhiteSpace([string]$legacyState.account)
      ) {
        throw "A legacy Beantime timer is still active; stop it before preparing the migrated profile."
      }
    }
  }

  $beanCheckOutput = & bean-check $resolvedLedger 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "The existing Nextcloud Beantime ledger failed bean-check; no profile was changed."
  }

  if (Test-Path -LiteralPath $projectBackupPath -PathType Leaf) {
    $currentCanonical = $current | ConvertTo-Json -Depth 20 -Compress
    $backup = Get-Content -LiteralPath $projectBackupPath -Raw | ConvertFrom-Json
    $backupCanonical = $backup | ConvertTo-Json -Depth 20 -Compress
    if ($currentCanonical -ne $backupCanonical) {
      throw "The project-profile backup differs from the active settings; Beantime preparation will not overwrite it."
    }
  }

  $current.modules.beantime = [pscustomobject][ordered]@{
    enabled = $true
    title = [string]$legacy.modules.beantime.title
    file = "beantime/zeit.beancount"
    personAccount = [string]$legacy.modules.beantime.personAccount
    stateFile = "beantime/state.json"
    bookableAccountPrefix = [string]$legacy.modules.beantime.bookableAccountPrefix
  }
  if (-not (Test-Path -LiteralPath $projectBackupPath -PathType Leaf)) {
    Copy-Item -LiteralPath $settingsPath -Destination $projectBackupPath
  }
  try {
    Write-JsonFile -Path $settingsPath -Value $current
    Write-JsonFile -Path $profilePath -Value ([ordered]@{
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
      beantimeLedgerPath = $ledgerRelativeToVault
      preparedAt = (Get-Date).ToString("o")
    })
  } catch {
    Copy-Item -LiteralPath $projectBackupPath -Destination $settingsPath -Force
    Write-JsonFile -Path $profilePath -Value ([ordered]@{
      version = 1
      profile = "homepage-project-creation"
      enabledModules = @("bookmarks", "clock", "newProject", "updo")
      writeCapabilities = @("project.create")
      preparedAt = (Get-Date).ToString("o")
    })
    throw
  }
}

$profile = Get-CurrentProfile
$profileData = if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
  Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
} else {
  $null
}
$settingsReady = Test-Path -LiteralPath $settingsPath -PathType Leaf
$enabledModules = @()
if ($settingsReady) {
  $currentSettings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
  $enabledModules = @(
    $currentSettings.modules.psobject.Properties |
      Where-Object { [bool]$_.Value.enabled } |
      ForEach-Object { $_.Name }
  )
}
$plannedProjectEnabled = [bool](
  $PrepareProjectProfile -or
  $PrepareBeantimeProfile -or
  $profile -in @("homepage-project-creation", "homepage-project-beantime")
)
$plannedBeantimeEnabled = [bool]($PrepareBeantimeProfile -or $profile -eq "homepage-project-beantime")
$plannedBeantimeLedgerPath = if ($profile -eq "homepage-project-beantime") {
  [string]$profileData.beantimeLedgerPath
} elseif ($PrepareBeantimeProfile) {
  $legacyPlanSettings = Get-Content -LiteralPath $legacySettingsPath -Raw | ConvertFrom-Json
  $legacyPlanLedger = [string]$legacyPlanSettings.modules.beantime.file
  if ([string]::IsNullOrWhiteSpace($legacyPlanLedger) -or [System.IO.Path]::IsPathRooted($legacyPlanLedger)) {
    throw "Legacy Beantime ledger configuration must be relative to the legacy Tools root."
  }
  $plannedLedgerCandidate = [System.IO.Path]::GetFullPath((Join-Path $resolvedLegacy $legacyPlanLedger))
  $plannedLegacyPrefix = $resolvedLegacy.TrimEnd('\') + '\'
  if (-not $plannedLedgerCandidate.StartsWith($plannedLegacyPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Legacy Beantime ledger configuration escapes the legacy Tools root."
  }
  $plannedResolvedLedger = (Resolve-Path -LiteralPath $plannedLedgerCandidate).Path
  if (-not $plannedResolvedLedger.StartsWith($vaultPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Beantime ledger must remain inside the configured Nextcloud vault."
  }
  $plannedResolvedLedger.Substring($vaultPrefix.Length).Replace('\', '/')
} else {
  $null
}
$plan = [ordered]@{
  component = "homepage-shell"
  repository = $repoRoot
  vaultAuthority = $resolvedVault
  obsidianVaultName = $ObsidianVaultName
  localState = $componentState
  port = $Port
  legacyHomepagePort = $LegacyHomepagePort
  mode = if ($plannedProjectEnabled -or $plannedBeantimeEnabled) { "limited-write" } else { "read-only" }
  currentProfile = $profile
  prepareShellProfile = [bool]$PrepareShellProfile
  prepareProjectProfile = [bool]$PrepareProjectProfile
  prepareBeantimeProfile = [bool]$PrepareBeantimeProfile
  settingsReady = $settingsReady
  monitoringBackupReady = Test-Path -LiteralPath $monitoringBackupPath -PathType Leaf
  enabledModules = $enabledModules
  legacyPreferenceSource = if ($PrepareShellProfile -or $PrepareProjectProfile -or $PrepareBeantimeProfile) { $resolvedLegacy } else { $null }
  projectCreationEnabled = $plannedProjectEnabled
  settingsManagementEnabled = $true
  obsidianOpenEnabled = $true
  beantimeEnabled = $plannedBeantimeEnabled
  beantimeLedgerAuthority = if ($plannedBeantimeEnabled) { "vault" } else { "none" }
  beantimeLedgerPath = $plannedBeantimeLedgerPath
  vaultWrites = [bool]($plannedProjectEnabled -or $plannedBeantimeEnabled)
  remoteWrites = $false
  productionProcessChanged = $false
}
$plan | ConvertTo-Json -Depth 4
if (-not $Apply) {
  Write-Host "Plan only. Re-run with -Apply after reviewing the profile, authority, state, and port."
  exit 0
}

$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($listener) { throw "Port $Port is already in use; no process was stopped." }
if ($plannedBeantimeEnabled -and (Get-NetTCPConnection -LocalPort $LegacyHomepagePort -State Listen -ErrorAction SilentlyContinue)) {
  throw "Legacy Homepage port $LegacyHomepagePort is still in use; Beantime was not enabled."
}
if ($plannedBeantimeEnabled -and (Get-NetTCPConnection -LocalPort $BeantimeFavaPort -State Listen -ErrorAction SilentlyContinue)) {
  throw "Beantime Fava port $BeantimeFavaPort is already in use; no process was stopped."
}
if (Test-Path -LiteralPath $monitoringManifestPath -PathType Leaf) {
  throw "The monitoring-only process is still registered; use stop-monitoring.ps1 first."
}
if (Test-Path -LiteralPath $homepageManifestPath -PathType Leaf) {
  throw "A Homepage shell process manifest already exists; use stop-homepage.ps1 first."
}
if ($profile -eq "invalid") { throw "The Homepage runtime profile is invalid." }

$preparedThisRun = $false
if ($PrepareShellProfile) {
  if ($profile -eq "homepage-shell") { throw "The Homepage shell profile is already active." }
  Prepare-HomepageShellProfile
  $preparedThisRun = $true
  $profile = "homepage-shell"
}
if ($PrepareProjectProfile) {
  if ($profile -eq "homepage-project-creation") { throw "The project-creation profile is already active." }
  Prepare-ProjectCreationProfile
  $preparedThisRun = $true
  $profile = "homepage-project-creation"
}
if ($PrepareBeantimeProfile) {
  if ($profile -eq "homepage-project-beantime") { throw "The Beantime profile is already active." }
  Prepare-BeantimeProfile
  $preparedThisRun = $true
  $profile = "homepage-project-beantime"
}
if ($profile -notin @("homepage-shell", "homepage-project-creation", "homepage-project-beantime")) {
  throw "No supported Homepage profile is active. Review and prepare the required profile first."
}

$profileData = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
$shellSettings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
$actualEnabled = @(
  $shellSettings.modules.psobject.Properties |
    Where-Object { [bool]$_.Value.enabled } |
    ForEach-Object { $_.Name }
)
$updoEnabled = [bool]$shellSettings.modules.updo.enabled
$projectCreationEnabled = $profile -in @("homepage-project-creation", "homepage-project-beantime")
$beantimeEnabled = $profile -eq "homepage-project-beantime"
$beantimeLedgerPath = if ($beantimeEnabled) { [string]$profileData.beantimeLedgerPath } else { "" }
if ($beantimeEnabled -and [string]::IsNullOrWhiteSpace($beantimeLedgerPath)) {
  throw "The Beantime profile has no vault-relative ledger path."
}
$targetCount = @($shellSettings.modules.updo.targets).Count
if ($updoEnabled -and -not $targetCount) { throw "Enabled Homepage monitoring has no targets." }

$env:NICA_VAULT_ROOT = $resolvedVault
$env:NICA_STATE_ROOT = $resolvedState
$env:NICA_WRITE_ENABLED = "false"
$env:NICA_PROJECT_CREATE_ENABLED = if ($projectCreationEnabled) { "true" } else { "false" }
$env:NICA_SETTINGS_MANAGE_ENABLED = "true"
$env:NICA_OBSIDIAN_ACTIONS_ENABLED = "true"
$env:NICA_BEANTIME_CAPABILITIES = if ($beantimeEnabled) {
  "beantime.read,beantime.timer,beantime.append,beantime.fava"
} else {
  ""
}
$env:NICA_BEANTIME_LEDGER_PATH = $beantimeLedgerPath
$env:OBSIDIAN_VAULT_NAME = $ObsidianVaultName
$env:HOMEPAGE_PORT = [string]$Port
$env:BEANTIME_FAVA_PORT = [string]$BeantimeFavaPort

$stdout = Join-Path $componentState "homepage.out.log"
$stderr = Join-Path $componentState "homepage.err.log"
$serverPath = Join-Path $repoRoot "serve.mjs"
$writeCapabilities = [string[]]@("settings.manage", "obsidian.open")
if ($projectCreationEnabled) { $writeCapabilities += "project.create" }
if ($beantimeEnabled) {
  $writeCapabilities += @("beantime.read", "beantime.timer", "beantime.append", "beantime.fava")
}
$proc = $null
try {
  $proc = Start-Process -FilePath "node" -ArgumentList ('"' + $serverPath + '"') -WorkingDirectory $repoRoot -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
  $manifest = [ordered]@{
    component = "homepage-shell"
    repository = $repoRoot
    vaultAuthority = $resolvedVault
    obsidianVaultName = $ObsidianVaultName
    stateRoot = $resolvedState
    port = $Port
    mode = "limited-write"
    writeCapabilities = $writeCapabilities
    enabledModules = $actualEnabled
    beantimeLedgerAuthority = if ($beantimeEnabled) { "vault" } else { "none" }
    beantimeLedgerPath = if ($beantimeEnabled) { $beantimeLedgerPath } else { $null }
    beantimeFavaPort = if ($beantimeEnabled) { $BeantimeFavaPort } else { $null }
    monitoringTargetCount = $targetCount
    pid = $proc.Id
    startedAt = (Get-Date).ToString("o")
    stdout = $stdout
    stderr = $stderr
  }
  $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $homepageManifestPath -Encoding utf8

  $healthy = $false
  for ($attempt = 0; $attempt -lt 40; $attempt += 1) {
    try {
      $ping = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/ping" -TimeoutSec 1
      $settingsResponse = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/settings" -TimeoutSec 2
      $bookmarksResponse = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/bookmarks" -TimeoutSec 2
      $monitorResponse = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/updo/snapshot" -TimeoutSec 2
      $healthEnabled = @(
        $settingsResponse.settings.modules.psobject.Properties |
          Where-Object { [bool]$_.Value.enabled } |
          ForEach-Object { $_.Name }
      )
      if (
        $ping.ok -and
        $ping.component -eq "homepage" -and
        $ping.mode -eq "limited-write" -and
        [bool]$ping.writesEnabled -and
        [bool]$ping.writeCapabilities.projectCreate -eq $projectCreationEnabled -and
        [bool]$ping.writeCapabilities.settingsManage -and
        [bool]$ping.writeCapabilities.obsidianOpen -and
        ([bool]$ping.writeCapabilities.beantimeRead -eq $beantimeEnabled) -and
        ([bool]$ping.writeCapabilities.beantimeTimer -eq $beantimeEnabled) -and
        ([bool]$ping.writeCapabilities.beantimeAppend -eq $beantimeEnabled) -and
        ([bool]$ping.writeCapabilities.beantimeFava -eq $beantimeEnabled) -and
        $ping.beantimeLedgerAuthority -eq $(if ($beantimeEnabled) { "vault" } else { "local-state" }) -and
        -not [bool]$ping.writeCapabilities.unrestricted -and
        $ping.authority.vault -eq $resolvedVault -and
        $ping.authority.localState -eq $componentState -and
        -not (Compare-Object -ReferenceObject $actualEnabled -DifferenceObject $healthEnabled) -and
        $null -ne $bookmarksResponse.items -and
        $monitorResponse.ok -and
        ([bool]$monitorResponse.running -eq $updoEnabled) -and
        (-not $updoEnabled -or @($monitorResponse.targets).Count -eq $targetCount) -and
        [string]::IsNullOrWhiteSpace([string]$monitorResponse.error)
      ) {
        if ($beantimeEnabled) {
          $beantimeMeta = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/beantime/meta" -TimeoutSec 2
          if (
            -not $beantimeMeta.ok -or
            $beantimeMeta.ledgerAuthority -ne "vault" -or
            $beantimeMeta.file -ne $beantimeLedgerPath -or
            @($beantimeMeta.accounts).Count -eq 0 -or
            @($beantimeMeta.personAccounts).Count -eq 0
          ) {
            continue
          }
        }
        $healthy = $true
        break
      }
    } catch { }
    Start-Sleep -Milliseconds 250
  }
  if (-not $healthy) { throw "Homepage shell did not become healthy with the planned profile and authority." }
} catch {
  if ($proc) {
    $children = @(Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $proc.Id })
    Stop-Process -Id $proc.Id -ErrorAction SilentlyContinue
    foreach ($child in $children) { Stop-Process -Id $child.ProcessId -ErrorAction SilentlyContinue }
  }
  Remove-Item -LiteralPath $homepageManifestPath -Force -ErrorAction SilentlyContinue
  if ($preparedThisRun -and $PrepareBeantimeProfile -and (Test-Path -LiteralPath $projectBackupPath -PathType Leaf)) {
    Copy-Item -LiteralPath $projectBackupPath -Destination $settingsPath -Force
    Write-JsonFile -Path $profilePath -Value ([ordered]@{
      version = 1
      profile = "homepage-project-creation"
      enabledModules = @("bookmarks", "clock", "newProject", "updo")
      writeCapabilities = @("project.create")
      preparedAt = (Get-Date).ToString("o")
    })
  } elseif ($preparedThisRun -and $PrepareProjectProfile -and (Test-Path -LiteralPath $shellBackupPath -PathType Leaf)) {
    Copy-Item -LiteralPath $shellBackupPath -Destination $settingsPath -Force
    Write-JsonFile -Path $profilePath -Value ([ordered]@{
      version = 1
      profile = "homepage-shell"
      enabledModules = @("bookmarks", "clock", "updo")
      preparedAt = (Get-Date).ToString("o")
    })
  } elseif ($preparedThisRun -and (Test-Path -LiteralPath $monitoringBackupPath -PathType Leaf)) {
    Copy-Item -LiteralPath $monitoringBackupPath -Destination $settingsPath -Force
    Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
  }
  throw
}

$manifest | ConvertTo-Json -Depth 4
