[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$VaultRoot,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [string]$LegacyToolsRoot = "",
  [int]$Port = 4274,
  [switch]$InitializeFromLegacy,
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
$resolvedLegacy = $null
$legacySettingsPath = $null
if ($InitializeFromLegacy) {
  $resolvedLegacy = (Resolve-Path -LiteralPath $legacyRootInput).Path
  $legacySettingsPath = Join-Path $resolvedLegacy "config\settings.local.json"
  if (-not (Test-Path -LiteralPath $legacySettingsPath -PathType Leaf)) {
    throw "Legacy monitoring settings were not found."
  }
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

$componentState = Join-Path $resolvedState "homepage"
$settingsPath = Join-Path $componentState "config\settings.local.json"
$profilePath = Join-Path $componentState "config\runtime-profile.json"
$manifestPath = Join-Path $componentState "monitoring-process.json"

function Resolve-ContainedPath {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if ([System.IO.Path]::IsPathRooted($RelativePath)) {
    throw "$Label must be relative."
  }
  $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
  $resolved = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot $RelativePath))
  if (-not $resolved.StartsWith($resolvedRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "$Label escapes its permitted root."
  }
  return $resolved
}

function Read-LegacySettings {
  $settings = Get-Content -LiteralPath $legacySettingsPath -Raw | ConvertFrom-Json
  $updo = $settings.modules.updo
  if (-not $updo -or -not [bool]$updo.enabled) {
    throw "Legacy monitoring is not enabled."
  }
  $targets = @($updo.targets)
  if (-not $targets.Count) { throw "Legacy monitoring has no targets." }
  foreach ($target in $targets) {
    $uri = $null
    if (-not [System.Uri]::TryCreate([string]$target.url, [System.UriKind]::Absolute, [ref]$uri)) {
      throw "Legacy monitoring contains an invalid target URL."
    }
    if ($uri.Scheme -notin @("http", "https")) {
      throw "Legacy monitoring contains a non-HTTP target URL."
    }
    if (
      -not [string]::IsNullOrWhiteSpace($uri.UserInfo) -or
      -not [string]::IsNullOrWhiteSpace($uri.Query) -or
      -not [string]::IsNullOrWhiteSpace($uri.Fragment)
    ) {
      throw "Legacy monitoring target URLs with user info, query strings, or fragments require manual review."
    }
  }
  return $settings
}

function Get-PersistenceMap {
  param(
    [Parameter(Mandatory = $true)]$UpdoSettings,
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$DestinationRoot
  )

  $entries = @(
    @{ name = "raw"; relative = [string]$UpdoSettings.persistence.rawFile; kind = "jsonl" },
    @{ name = "longterm"; relative = [string]$UpdoSettings.persistence.longtermFile; kind = "jsonl" },
    @{ name = "incidents"; relative = [string]$UpdoSettings.persistence.incidentsFile; kind = "jsonl" },
    @{ name = "state"; relative = [string]$UpdoSettings.persistence.stateFile; kind = "json" }
  )
  foreach ($entry in $entries) {
    if ([string]::IsNullOrWhiteSpace($entry.relative)) {
      throw "Legacy monitoring persistence path '$($entry.name)' is empty."
    }
    [pscustomobject]@{
      Name = $entry.name
      Kind = $entry.kind
      Relative = $entry.relative
      Source = Resolve-ContainedPath -Root $SourceRoot -RelativePath $entry.relative -Label "$($entry.name) source path"
      Destination = Resolve-ContainedPath -Root $DestinationRoot -RelativePath $entry.relative -Label "$($entry.name) destination path"
    }
  }
}

function Test-JsonLines {
  param([Parameter(Mandatory = $true)][string]$Path)
  $lineNumber = 0
  foreach ($line in [System.IO.File]::ReadLines($Path)) {
    $lineNumber += 1
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $null = $line | ConvertFrom-Json } catch {
      throw "Invalid JSONL in $(Split-Path -Leaf $Path) at line $lineNumber."
    }
  }
}

function Initialize-MonitoringState {
  if (Test-Path -LiteralPath $componentState) {
    throw "Monitoring destination already exists; initialization will not overwrite it."
  }
  New-Item -ItemType Directory -Force -Path $resolvedState | Out-Null
  $stage = Join-Path $resolvedState (".monitoring-import-" + [guid]::NewGuid().ToString("N"))
  $snapshotDir = Join-Path $stage "_source"
  New-Item -ItemType Directory -Force -Path $snapshotDir | Out-Null

  try {
    $stable = $false
    $copiedSettings = Join-Path $snapshotDir "settings.local.json"
    for ($attempt = 1; $attempt -le 10; $attempt += 1) {
      Get-ChildItem -LiteralPath $snapshotDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
      $legacySettings = Read-LegacySettings
      $map = @(Get-PersistenceMap -UpdoSettings $legacySettings.modules.updo -SourceRoot $resolvedLegacy -DestinationRoot $stage)
      foreach ($entry in $map) {
        if (-not (Test-Path -LiteralPath $entry.Source -PathType Leaf)) {
          throw "Legacy monitoring state file '$($entry.Name)' is missing."
        }
      }
      $sourcePaths = @($legacySettingsPath) + @($map | ForEach-Object { $_.Source })
      $before = @{}
      foreach ($sourcePath in $sourcePaths) {
        $item = Get-Item -LiteralPath $sourcePath
        $before[$sourcePath] = "$($item.Length):$($item.LastWriteTimeUtc.Ticks)"
      }

      Copy-Item -LiteralPath $legacySettingsPath -Destination $copiedSettings -Force
      foreach ($entry in $map) {
        Copy-Item -LiteralPath $entry.Source -Destination (Join-Path $snapshotDir ($entry.Name + "." + $entry.Kind)) -Force
      }

      $stable = $true
      foreach ($sourcePath in $sourcePaths) {
        $item = Get-Item -LiteralPath $sourcePath
        if ($before[$sourcePath] -ne "$($item.Length):$($item.LastWriteTimeUtc.Ticks)") {
          $stable = $false
          break
        }
      }
      if ($stable) { break }
      Start-Sleep -Milliseconds 250
    }
    if (-not $stable) { throw "Could not capture a stable monitoring-state snapshot." }

    $snapshotSettings = Get-Content -LiteralPath $copiedSettings -Raw | ConvertFrom-Json
    $map = @(Get-PersistenceMap -UpdoSettings $snapshotSettings.modules.updo -SourceRoot $resolvedLegacy -DestinationRoot $stage)
    foreach ($entry in $map) {
      $snapshotFile = Join-Path $snapshotDir ($entry.Name + "." + $entry.Kind)
      if ($entry.Kind -eq "jsonl") {
        Test-JsonLines -Path $snapshotFile
      } else {
        $null = Get-Content -LiteralPath $snapshotFile -Raw | ConvertFrom-Json
      }
      $destinationParent = Split-Path -Parent $entry.Destination
      New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null
      Move-Item -LiteralPath $snapshotFile -Destination $entry.Destination
    }

    $localSettings = [ordered]@{
      schemaVersion = 1
      ui = [ordered]@{ title = "NICA Website Monitoring" }
      modules = [ordered]@{
        bookmarks = [ordered]@{ enabled = $false }
        clock = [ordered]@{ enabled = $false }
        newProject = [ordered]@{ enabled = $false }
        beantime = [ordered]@{ enabled = $false }
        vaultGraph = [ordered]@{ enabled = $false }
        email = [ordered]@{ enabled = $false }
        updo = $snapshotSettings.modules.updo
      }
    }
    $stageSettings = Join-Path $stage "config\settings.local.json"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $stageSettings) | Out-Null
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText(
      $stageSettings,
      (($localSettings | ConvertTo-Json -Depth 20) + [Environment]::NewLine),
      $utf8NoBom
    )
    Remove-Item -LiteralPath $snapshotDir -Recurse -Force
    Move-Item -LiteralPath $stage -Destination $componentState
  } catch {
    if (Test-Path -LiteralPath $stage) {
      Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw
  }
}

$destinationReady = Test-Path -LiteralPath $settingsPath -PathType Leaf
$runtimeProfile = "monitoring-only"
if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
  try {
    $profileData = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    $runtimeProfile = [string]$profileData.profile
  } catch {
    $runtimeProfile = "invalid"
  }
}
$planTargetCount = 0
$legacyStateFileCount = 0
if ($InitializeFromLegacy) {
  $legacySettings = Read-LegacySettings
  $legacyMap = @(Get-PersistenceMap -UpdoSettings $legacySettings.modules.updo -SourceRoot $resolvedLegacy -DestinationRoot $componentState)
  $planTargetCount = @($legacySettings.modules.updo.targets).Count
  $legacyStateFileCount = @($legacyMap | Where-Object { Test-Path -LiteralPath $_.Source }).Count
} elseif ($destinationReady) {
  $existingSettings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
  $planTargetCount = @($existingSettings.modules.updo.targets).Count
}
$plan = [ordered]@{
  component = "monitoring"
  repository = $repoRoot
  vaultAuthority = $resolvedVault
  legacySource = if ($InitializeFromLegacy) { $resolvedLegacy } else { $null }
  localState = $componentState
  port = $Port
  mode = "read-only-authority-with-local-derived-writes"
  targetCount = $planTargetCount
  legacyStateFiles = $legacyStateFileCount
  initializeFromLegacy = [bool]$InitializeFromLegacy
  destinationReady = $destinationReady
  runtimeProfile = $runtimeProfile
  vaultWrites = $false
  remoteWrites = $false
  unrelatedHomepageModules = $false
  productionProcessChanged = $false
}
$plan | ConvertTo-Json -Depth 4
if (-not $Apply) {
  Write-Host "Plan only. Re-run with -Apply after reviewing the authority, state, initialization, and port."
  exit 0
}

$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($listener) { throw "Port $Port is already in use; no process was stopped." }
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
  throw "A monitoring process manifest already exists; use stop-monitoring.ps1 first."
}
if ($runtimeProfile -eq "homepage-shell") {
  throw "The Homepage shell profile is active; use start-homepage.ps1 instead."
}
if ($runtimeProfile -eq "invalid") {
  throw "The Homepage runtime profile is invalid."
}
if ($InitializeFromLegacy) { Initialize-MonitoringState }
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
  throw "Monitoring state is not initialized. Review and apply with -InitializeFromLegacy once."
}

$localSettings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
$targetCount = @($localSettings.modules.updo.targets).Count
if (-not [bool]$localSettings.modules.updo.enabled -or -not $targetCount) {
  throw "Monitoring local settings are disabled or have no targets."
}

$env:NICA_VAULT_ROOT = $resolvedVault
$env:NICA_STATE_ROOT = $resolvedState
$env:NICA_WRITE_ENABLED = "false"
$env:NICA_OBSIDIAN_ACTIONS_ENABLED = "false"
$env:HOMEPAGE_PORT = [string]$Port

New-Item -ItemType Directory -Force -Path $componentState | Out-Null
$stdout = Join-Path $componentState "monitoring.out.log"
$stderr = Join-Path $componentState "monitoring.err.log"
$serverPath = Join-Path $repoRoot "serve.mjs"
$proc = Start-Process -FilePath "node" -ArgumentList ('"' + $serverPath + '"') -WorkingDirectory $repoRoot -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
$manifest = [ordered]@{
  component = "monitoring"
  repository = $repoRoot
  vaultAuthority = $resolvedVault
  stateRoot = $resolvedState
  port = $Port
  mode = "read-only-authority-with-local-derived-writes"
  targetCount = $targetCount
  pid = $proc.Id
  startedAt = (Get-Date).ToString("o")
  stdout = $stdout
  stderr = $stderr
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding utf8

try {
  $healthy = $false
  for ($attempt = 0; $attempt -lt 40; $attempt += 1) {
    try {
      $ping = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/ping" -TimeoutSec 1
      $snapshot = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/updo/snapshot" -TimeoutSec 2
      if (
        $ping.ok -and
        $ping.component -eq "homepage" -and
        $ping.mode -eq "read-only" -and
        -not [bool]$ping.writesEnabled -and
        $ping.authority.vault -eq $resolvedVault -and
        $ping.authority.localState -eq $componentState -and
        $snapshot.ok -and
        $snapshot.running -and
        @($snapshot.targets).Count -eq $targetCount -and
        [string]::IsNullOrWhiteSpace([string]$snapshot.error)
      ) {
        $healthy = $true
        break
      }
    } catch { }
    Start-Sleep -Milliseconds 250
  }
  if (-not $healthy) { throw "Monitoring did not become healthy with the planned authority and target count." }
} catch {
  $children = @(Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $proc.Id })
  Stop-Process -Id $proc.Id -ErrorAction SilentlyContinue
  foreach ($child in $children) { Stop-Process -Id $child.ProcessId -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
  throw
}

$manifest | ConvertTo-Json -Depth 4
