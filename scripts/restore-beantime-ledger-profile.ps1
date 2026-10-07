[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$VaultRoot,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$resolvedVault = (Resolve-Path -LiteralPath $VaultRoot).Path
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)
$componentState = Join-Path $resolvedState "homepage"
$profilePath = Join-Path $componentState "config\runtime-profile.json"
$settingsPath = Join-Path $componentState "config\settings.local.json"
$manifestPath = Join-Path $componentState "homepage-process.json"
$timerStatePath = Join-Path $componentState "beantime\state.json"
$recordPath = Join-Path $resolvedState "launcher\beantime-ledger-migration.json"

function Resolve-ContainedVaultFile {
  param([Parameter(Mandatory = $true)][string]$RelativePath)
  if ([System.IO.Path]::IsPathRooted($RelativePath)) { throw "Recorded ledger paths must be vault-relative." }
  $candidate = [System.IO.Path]::GetFullPath((Join-Path $resolvedVault $RelativePath))
  $prefix = $resolvedVault.TrimEnd('\') + '\'
  if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Recorded ledger path escapes the configured vault root."
  }
  return (Resolve-Path -LiteralPath $candidate).Path
}

function Write-JsonAtomic {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)
  $directory = Split-Path -Parent $Path
  $staged = Join-Path $directory ((Split-Path -Leaf $Path) + "." + [Guid]::NewGuid().ToString("N") + ".tmp")
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  try {
    [System.IO.File]::WriteAllText($staged, (($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine), $utf8NoBom)
    Get-Content -LiteralPath $staged -Raw | ConvertFrom-Json | Out-Null
    Move-Item -LiteralPath $staged -Destination $Path -Force
  } finally {
    Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
  }
}

foreach ($required in @($profilePath, $settingsPath, $recordPath)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required migration state is missing: $required" }
}
$profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
$settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
$record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
$sourceRelative = [string]$record.source
$destinationRelative = [string]$record.destination
$sourcePath = Resolve-ContainedVaultFile $sourceRelative
$destinationPath = Resolve-ContainedVaultFile $destinationRelative
$sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
$destinationHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash
$homepageRunning = $false
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
  try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $homepageRunning = $null -ne (Get-CimInstance Win32_Process -Filter "ProcessId = $($manifest.pid)" -ErrorAction SilentlyContinue)
  } catch { }
}
$activeTimer = $false
if (Test-Path -LiteralPath $timerStatePath -PathType Leaf) {
  try {
    $timerState = Get-Content -LiteralPath $timerStatePath -Raw | ConvertFrom-Json
    $activeTimer = -not [string]::IsNullOrWhiteSpace([string]$timerState.startedAt) -and -not [string]::IsNullOrWhiteSpace([string]$timerState.account)
  } catch {
    throw "The Beantime timer-state file is invalid; profile rollback is blocked."
  }
}

[ordered]@{
  action = if ($sourceHash -eq $destinationHash) { "restore-source-profile" } else { "sync-destination-back-and-restore-source-profile" }
  source = $sourceRelative
  destination = $destinationRelative
  sourceSha256 = $sourceHash
  destinationSha256 = $destinationHash
  contentMatches = $sourceHash -eq $destinationHash
  homepageRunning = $homepageRunning
  activeTimer = $activeTimer
  filesRetained = $true
} | ConvertTo-Json -Depth 4

if (-not $Apply) {
  Write-Host "Plan only. If the destination has new bookings, Apply first synchronizes it back to the unchanged retained source."
  return
}
if ($homepageRunning) { throw "Stop Homepage before restoring its prior Beantime ledger profile." }
if ($activeTimer) { throw "Stop the active Beantime timer before restoring the prior ledger profile." }
if ([string]$profile.beantimeLedgerPath -ne $destinationRelative) {
  throw "Homepage is not configured for the migrated Beantime ledger; no profile was changed."
}
if ($sourceHash -ne [string]$record.sourceSha256) {
  throw "The retained source ledger changed after migration; automatic rollback cannot choose a safe winner."
}
if ($sourceHash -ne $destinationHash) {
  $recoveryDirectory = Join-Path $resolvedState "launcher\recovery"
  New-Item -ItemType Directory -Force -Path $recoveryDirectory | Out-Null
  $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
  $recoveryPath = Join-Path $recoveryDirectory "beantime-source-pre-rollback-$stamp.beancount"
  Copy-Item -LiteralPath $sourcePath -Destination $recoveryPath
  if ((Get-FileHash -LiteralPath $recoveryPath -Algorithm SHA256).Hash -ne $sourceHash) {
    Remove-Item -LiteralPath $recoveryPath -Force -ErrorAction SilentlyContinue
    throw "The local recovery copy of the retained source failed verification."
  }
  $sourceDirectory = Split-Path -Parent $sourcePath
  $stagedSource = Join-Path $sourceDirectory (".zeit-rollback." + [Guid]::NewGuid().ToString("N") + ".tmp")
  $replaceBackup = Join-Path $sourceDirectory (".zeit-rollback-backup." + [Guid]::NewGuid().ToString("N") + ".tmp")
  try {
    Copy-Item -LiteralPath $destinationPath -Destination $stagedSource
    if ((Get-FileHash -LiteralPath $stagedSource -Algorithm SHA256).Hash -ne $destinationHash) {
      throw "The staged rollback ledger does not match the migrated destination."
    }
    [System.IO.File]::Replace($stagedSource, $sourcePath, $replaceBackup)
  } finally {
    Remove-Item -LiteralPath $stagedSource -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
  }
  if ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -ne $destinationHash) {
    throw "The restored source ledger does not match the migrated destination."
  }
  $record | Add-Member -NotePropertyName rollbackRecoveryCopy -NotePropertyValue $recoveryPath -Force
}

$profile.beantimeLedgerPath = $sourceRelative
$settings.modules.beantime.file = $sourceRelative
$record | Add-Member -NotePropertyName profileRestoredAt -NotePropertyValue (Get-Date).ToString("o") -Force
Write-JsonAtomic -Path $profilePath -Value $profile
Write-JsonAtomic -Path $settingsPath -Value $settings
Write-JsonAtomic -Path $recordPath -Value $record
Write-Host "Homepage was switched back to the retained source path without losing migrated bookings. Both ledger files were preserved."
