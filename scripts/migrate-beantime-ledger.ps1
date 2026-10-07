[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$VaultRoot,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [string]$DestinationRelativePath = "1. Vereinsverwaltung/Buchhaltung/Zeiterfassung/zeit.beancount",
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

function Resolve-ContainedVaultPath {
  param(
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [switch]$MustExist
  )
  if ([System.IO.Path]::IsPathRooted($RelativePath)) {
    throw "Beantime ledger paths must be relative to the configured vault root."
  }
  $candidate = [System.IO.Path]::GetFullPath((Join-Path $resolvedVault $RelativePath))
  $prefix = $resolvedVault.TrimEnd('\') + '\'
  if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Beantime ledger path escapes the configured vault root."
  }
  if ($MustExist -and -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    throw "Beantime ledger was not found: $RelativePath"
  }
  return $candidate
}

function Write-JsonAtomic {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )
  $directory = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
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

foreach ($required in @($profilePath, $settingsPath)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Required Homepage runtime configuration is missing: $required"
  }
}
$profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
$settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
if ([string]$profile.profile -ne "homepage-project-beantime") {
  throw "The accepted Beantime Homepage profile is not active."
}
$sourceRelativePath = [string]$profile.beantimeLedgerPath
if ([string]::IsNullOrWhiteSpace($sourceRelativePath)) {
  throw "The Beantime runtime profile has no source ledger path."
}
$sourcePath = Resolve-ContainedVaultPath -RelativePath $sourceRelativePath -MustExist
$destinationPath = Resolve-ContainedVaultPath -RelativePath $DestinationRelativePath
$destinationNormalized = $DestinationRelativePath.Replace('\', '/').TrimStart('/')
if ($destinationNormalized.StartsWith("Tools/", [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "The destination must be outside the retiring Tools checkout."
}
if ($sourcePath -eq $destinationPath) {
  throw "The Beantime ledger is already configured at the requested destination."
}
$sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
$destinationExists = Test-Path -LiteralPath $destinationPath -PathType Leaf
$destinationHash = if ($destinationExists) { (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash } else { $null }
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
    throw "The Beantime timer-state file is invalid; ledger migration is blocked."
  }
}

[ordered]@{
  action = if (-not $destinationExists) { "copy-and-switch" } elseif ($destinationHash -eq $sourceHash) { "switch-to-existing-copy" } else { "destination-conflict" }
  source = $sourceRelativePath.Replace('\', '/')
  destination = $destinationNormalized
  sourceSha256 = $sourceHash
  destinationExists = $destinationExists
  destinationSha256 = $destinationHash
  homepageRunning = $homepageRunning
  activeTimer = $activeTimer
  sourceRetainedForRollback = $true
} | ConvertTo-Json -Depth 4

if (-not $Apply) {
  Write-Host "Plan only. Stop Homepage and re-run with -Apply after reviewing the ledger paths and hashes."
  return
}
if ($homepageRunning) { throw "Stop Homepage before switching its authoritative Beantime ledger." }
if ($activeTimer) { throw "Stop the active Beantime timer before switching ledgers." }
if ($destinationExists -and $destinationHash -ne $sourceHash) {
  throw "Destination already exists with different content; no file or runtime configuration was changed."
}

$destinationDirectory = Split-Path -Parent $destinationPath
New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
$stagedLedger = Join-Path $destinationDirectory (".zeit." + [Guid]::NewGuid().ToString("N") + ".tmp")
$profileOriginal = Get-Content -LiteralPath $profilePath -Raw
$settingsOriginal = Get-Content -LiteralPath $settingsPath -Raw
$published = $false
try {
  if (-not $destinationExists) {
    Copy-Item -LiteralPath $sourcePath -Destination $stagedLedger
    if ((Get-FileHash -LiteralPath $stagedLedger -Algorithm SHA256).Hash -ne $sourceHash) {
      throw "Staged Beantime ledger hash does not match the source."
    }
    Move-Item -LiteralPath $stagedLedger -Destination $destinationPath
    $published = $true
  }
  if ((Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash -ne $sourceHash) {
    throw "Published Beantime ledger hash does not match the source."
  }
  if ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -ne $sourceHash) {
    throw "Source Beantime ledger changed during migration; runtime configuration was not switched."
  }
  $profile.beantimeLedgerPath = $destinationNormalized
  $profile | Add-Member -NotePropertyName preMigrationBeantimeLedgerPath -NotePropertyValue $sourceRelativePath.Replace('\', '/') -Force
  $profile | Add-Member -NotePropertyName beantimeLedgerMigratedAt -NotePropertyValue (Get-Date).ToString("o") -Force
  $settings.modules.beantime.file = $destinationNormalized
  Write-JsonAtomic -Path $profilePath -Value $profile
  Write-JsonAtomic -Path $settingsPath -Value $settings
  Write-JsonAtomic -Path $recordPath -Value ([ordered]@{
    version = 1
    source = $sourceRelativePath.Replace('\', '/')
    destination = $destinationNormalized
    sourceSha256 = $sourceHash
    appliedAt = (Get-Date).ToString("o")
    sourceRetainedForRollback = $true
  })
} catch {
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($profilePath, $profileOriginal, $utf8NoBom)
  [System.IO.File]::WriteAllText($settingsPath, $settingsOriginal, $utf8NoBom)
  if ($published) { Remove-Item -LiteralPath $destinationPath -Force -ErrorAction SilentlyContinue }
  throw
} finally {
  Remove-Item -LiteralPath $stagedLedger -Force -ErrorAction SilentlyContinue
}
Write-Host "Beantime ledger copied to its vault-owned location and the migrated runtime profile was switched. The source file was retained for rollback."
