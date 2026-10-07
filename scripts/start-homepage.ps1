[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$VaultRoot,
  [Parameter(Mandatory = $true)][string]$ObsidianVaultName,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [string]$LegacyToolsRoot = "",
  [int]$Port = 4274,
  [switch]$PrepareShellProfile,
  [switch]$PrepareProjectProfile,
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
if ([string]::IsNullOrWhiteSpace($ObsidianVaultName)) {
  throw "ObsidianVaultName is required for explicit Obsidian CLI reads."
}
if ($PrepareShellProfile -and $PrepareProjectProfile) {
  throw "PrepareShellProfile and PrepareProjectProfile are mutually exclusive."
}

$componentState = Join-Path $resolvedState "homepage"
$configDir = Join-Path $componentState "config"
$settingsPath = Join-Path $configDir "settings.local.json"
$monitoringBackupPath = Join-Path $configDir "settings.monitoring-only.json"
$shellBackupPath = Join-Path $configDir "settings.homepage-shell.json"
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
if ($PrepareShellProfile -or $PrepareProjectProfile) {
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

$profile = Get-CurrentProfile
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
$plan = [ordered]@{
  component = "homepage-shell"
  repository = $repoRoot
  vaultAuthority = $resolvedVault
  obsidianVaultName = $ObsidianVaultName
  localState = $componentState
  port = $Port
  mode = if ($PrepareProjectProfile -or $profile -eq "homepage-project-creation") { "limited-write" } else { "read-only" }
  currentProfile = $profile
  prepareShellProfile = [bool]$PrepareShellProfile
  prepareProjectProfile = [bool]$PrepareProjectProfile
  settingsReady = $settingsReady
  monitoringBackupReady = Test-Path -LiteralPath $monitoringBackupPath -PathType Leaf
  enabledModules = $enabledModules
  legacyPreferenceSource = if ($PrepareShellProfile -or $PrepareProjectProfile) { $resolvedLegacy } else { $null }
  projectCreationEnabled = [bool]($PrepareProjectProfile -or $profile -eq "homepage-project-creation")
  vaultWrites = [bool]($PrepareProjectProfile -or $profile -eq "homepage-project-creation")
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
if ($profile -notin @("homepage-shell", "homepage-project-creation")) {
  throw "No supported Homepage profile is active. Review and prepare the required profile first."
}

$shellSettings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
$actualEnabled = @(
  $shellSettings.modules.psobject.Properties |
    Where-Object { [bool]$_.Value.enabled } |
    ForEach-Object { $_.Name }
)
$projectCreationEnabled = $profile -eq "homepage-project-creation"
$expectedEnabled = if ($projectCreationEnabled) {
  @("bookmarks", "clock", "newProject", "updo")
} else {
  @("bookmarks", "clock", "updo")
}
if (Compare-Object -ReferenceObject $expectedEnabled -DifferenceObject $actualEnabled) {
  throw "Homepage shell profile does not contain the expected enabled modules."
}
$targetCount = @($shellSettings.modules.updo.targets).Count
if (-not $targetCount) { throw "Homepage shell profile has no monitoring targets." }

$env:NICA_VAULT_ROOT = $resolvedVault
$env:NICA_STATE_ROOT = $resolvedState
$env:NICA_WRITE_ENABLED = "false"
$env:NICA_PROJECT_CREATE_ENABLED = if ($projectCreationEnabled) { "true" } else { "false" }
$env:NICA_OBSIDIAN_ACTIONS_ENABLED = if ($projectCreationEnabled) { "true" } else { "false" }
$env:OBSIDIAN_VAULT_NAME = $ObsidianVaultName
$env:HOMEPAGE_PORT = [string]$Port

$stdout = Join-Path $componentState "homepage.out.log"
$stderr = Join-Path $componentState "homepage.err.log"
$serverPath = Join-Path $repoRoot "serve.mjs"
$writeCapabilities = [string[]]@()
if ($projectCreationEnabled) { $writeCapabilities = [string[]]@("project.create") }
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
    mode = if ($projectCreationEnabled) { "limited-write" } else { "read-only" }
    writeCapabilities = $writeCapabilities
    enabledModules = $expectedEnabled
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
        $ping.mode -eq $(if ($projectCreationEnabled) { "limited-write" } else { "read-only" }) -and
        [bool]$ping.writesEnabled -eq $projectCreationEnabled -and
        [bool]$ping.writeCapabilities.projectCreate -eq $projectCreationEnabled -and
        -not [bool]$ping.writeCapabilities.unrestricted -and
        $ping.authority.vault -eq $resolvedVault -and
        $ping.authority.localState -eq $componentState -and
        -not (Compare-Object -ReferenceObject $expectedEnabled -DifferenceObject $healthEnabled) -and
        $null -ne $bookmarksResponse.items -and
        $monitorResponse.ok -and
        $monitorResponse.running -and
        @($monitorResponse.targets).Count -eq $targetCount -and
        [string]::IsNullOrWhiteSpace([string]$monitorResponse.error)
      ) {
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
  if ($preparedThisRun -and $PrepareProjectProfile -and (Test-Path -LiteralPath $shellBackupPath -PathType Leaf)) {
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
