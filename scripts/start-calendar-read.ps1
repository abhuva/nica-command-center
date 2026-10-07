[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$VaultRoot,
  [Parameter(Mandatory = $true)][string]$ObsidianVaultName,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [string]$LegacyToolsRoot = "",
  [int]$Port = 4273,
  [switch]$InitializeReadProfile,
  [switch]$AllowMarkdownFallback,
  [switch]$EnableVaultEventCreate,
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$calendarRoot = Join-Path $repoRoot "Calendar"
$resolvedVault = (Resolve-Path -LiteralPath $VaultRoot).Path
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)
$legacyRootInput = if ([string]::IsNullOrWhiteSpace($LegacyToolsRoot)) {
  Join-Path $resolvedVault "Tools"
} else {
  $LegacyToolsRoot
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
if ([string]::IsNullOrWhiteSpace($ObsidianVaultName)) {
  throw "ObsidianVaultName is required for explicit Obsidian CLI reads."
}

$componentState = Join-Path $resolvedState "calendar"
$configDir = Join-Path $componentState "config"
$readProfilePath = Join-Path $configDir "calendar-read.env"
$manifestPath = Join-Path $componentState "calendar-read-process.json"
$pidPath = Join-Path $componentState "calendar.preview.pid"
$generatedEventsPath = Join-Path $componentState "events.generated.js"
$componentName = if ($EnableVaultEventCreate) { "calendar-vault-write" } else { "calendar-read" }
$runtimeMode = if ($EnableVaultEventCreate) { "limited-write" } else { "read-only" }
$writeCapabilities = [System.Collections.Generic.List[string]]::new()
if ($EnableVaultEventCreate) { $writeCapabilities.Add("vault-event.create") }
$legacyEnvPath = $null
$resolvedLegacy = $null
if ($InitializeReadProfile) {
  $resolvedLegacy = (Resolve-Path -LiteralPath $legacyRootInput).Path
  $legacyEnvPath = Join-Path $resolvedLegacy "Calendar\.env.local"
  if (-not (Test-Path -LiteralPath $legacyEnvPath -PathType Leaf)) {
    throw "Legacy Calendar configuration was not found."
  }
}

$readProfileKeys = @(
  "OBSIDIAN_BASE_PATH",
  "OBSIDIAN_BASE_VIEW",
  "CALENDAR_INBOX_PATH",
  "GOOGLE_CALENDAR_API_KEY",
  "GOOGLE_CALENDAR_IDS",
  "NEXTCLOUD_CALDAV_BASE_URL",
  "NEXTCLOUD_CALDAV_USERNAME",
  "NEXTCLOUD_CALDAV_APP_PASSWORD",
  "NEXTCLOUD_CALDAV_CALENDARS"
)
$blockedCredentialKeys = @(
  "CALENDAR_API_TOKEN",
  "GOOGLE_OAUTH_CLIENT_ID",
  "GOOGLE_OAUTH_CLIENT_SECRET",
  "GOOGLE_OAUTH_REDIRECT_URI",
  "GOOGLE_OAUTH_SCOPES",
  "GOOGLE_OAUTH_TOKEN_FILE",
  "GOOGLE_CREATE_CALENDAR_ID",
  "NEXTCLOUD_CREATE_CALENDAR_ID",
  "CALENDAR_PUBLIC_EXPORT_DIR",
  "CALENDAR_PUBLIC_SFTP_URL",
  "CALENDAR_PUBLIC_SFTP_USER",
  "CALENDAR_PUBLIC_SFTP_PASSWORD",
  "CALENDAR_PUBLIC_SFTP_HOST_FINGERPRINT_SHA256"
)

function ConvertFrom-DotEnvScalar {
  param([Parameter(Mandatory = $true)][string]$RawValue)
  $value = $RawValue.Trim()
  if (
    $value.Length -ge 2 -and
    (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))
  ) {
    return $value.Substring(1, $value.Length - 2)
  }
  $hashIndex = $value.IndexOf('#')
  if ($hashIndex -ge 0) { $value = $value.Substring(0, $hashIndex) }
  return $value.Trim()
}

function Read-DotEnvEntries {
  param([Parameter(Mandatory = $true)][string]$Path)
  $entries = [ordered]@{}
  foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
    if ($line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { continue }
    $key = $matches[1]
    if ($entries.Contains($key)) { throw "Calendar configuration contains duplicate key '$key'." }
    $entries[$key] = [pscustomobject]@{
      Key = $key
      RawLine = $line
      Value = ConvertFrom-DotEnvScalar -RawValue $matches[2]
    }
  }
  return $entries
}

function Get-ReadProfile {
  param([Parameter(Mandatory = $true)][string]$Path)
  $entries = Read-DotEnvEntries -Path $Path
  $unexpected = @($entries.Keys | Where-Object { $_ -notin $readProfileKeys })
  if ($Path -eq $readProfilePath -and $unexpected.Count) {
    throw "Calendar read profile contains unsupported keys: $($unexpected -join ', ')."
  }

  $included = @($readProfileKeys | Where-Object { $entries.Contains($_) -and -not [string]::IsNullOrWhiteSpace($entries[$_].Value) })
  $googlePresent = @("GOOGLE_CALENDAR_API_KEY", "GOOGLE_CALENDAR_IDS" | Where-Object {
    $entries.Contains($_) -and -not [string]::IsNullOrWhiteSpace($entries[$_].Value)
  })
  if ($googlePresent.Count -notin @(0, 2)) {
    throw "Google Calendar reads require both GOOGLE_CALENDAR_API_KEY and GOOGLE_CALENDAR_IDS."
  }

  $nextcloudRequired = @(
    "NEXTCLOUD_CALDAV_BASE_URL",
    "NEXTCLOUD_CALDAV_USERNAME",
    "NEXTCLOUD_CALDAV_APP_PASSWORD",
    "NEXTCLOUD_CALDAV_CALENDARS"
  )
  $nextcloudPresent = @($nextcloudRequired | Where-Object {
    $entries.Contains($_) -and -not [string]::IsNullOrWhiteSpace($entries[$_].Value)
  })
  if ($nextcloudPresent.Count -notin @(0, $nextcloudRequired.Count)) {
    throw "Nextcloud Calendar reads require the complete NEXTCLOUD_CALDAV read configuration."
  }
  if (-not $googlePresent.Count -and -not $nextcloudPresent.Count) {
    throw "Calendar read profile has no external calendar source."
  }

  if ($nextcloudPresent.Count) {
    $uri = $null
    $baseUrl = $entries["NEXTCLOUD_CALDAV_BASE_URL"].Value
    if (-not [System.Uri]::TryCreate($baseUrl, [System.UriKind]::Absolute, [ref]$uri)) {
      throw "NEXTCLOUD_CALDAV_BASE_URL must be an absolute URL."
    }
    $secureScheme = $uri.Scheme -eq "https"
    $localTestScheme = $uri.Scheme -eq "http" -and $uri.IsLoopback
    if (-not $secureScheme -and -not $localTestScheme) {
      throw "NEXTCLOUD_CALDAV_BASE_URL must use HTTPS except for loopback test fixtures."
    }
    if ($uri.UserInfo -or $uri.Query -or $uri.Fragment) {
      throw "NEXTCLOUD_CALDAV_BASE_URL must not contain user info, a query, or a fragment."
    }
  }

  $lines = @(
    "# Generated read-only Calendar profile. Values are local secrets; do not commit this file."
    "# OAuth, remote write targets, and SFTP publishing credentials are intentionally excluded."
  )
  foreach ($key in $readProfileKeys) {
    if ($included -contains $key) { $lines += $entries[$key].RawLine }
  }
  [pscustomobject]@{
    Lines = $lines
    IncludedKeys = $included
    ExcludedKeys = @($entries.Keys | Where-Object { $_ -notin $included })
    GoogleCalendarCount = if ($googlePresent.Count) { @($entries["GOOGLE_CALENDAR_IDS"].Value.Split(',') | Where-Object { $_.Trim() }).Count } else { 0 }
    NextcloudCalendarCount = if ($nextcloudPresent.Count) { @($entries["NEXTCLOUD_CALDAV_CALENDARS"].Value.Split(',') | Where-Object { $_.Trim() }).Count } else { 0 }
  }
}

function Initialize-ReadProfile {
  if (Test-Path -LiteralPath $readProfilePath) {
    throw "Calendar read profile already exists; initialization will not overwrite it."
  }
  $beforeHash = (Get-FileHash -LiteralPath $legacyEnvPath -Algorithm SHA256).Hash
  $profile = Get-ReadProfile -Path $legacyEnvPath
  $afterHash = (Get-FileHash -LiteralPath $legacyEnvPath -Algorithm SHA256).Hash
  if ($beforeHash -ne $afterHash) { throw "Legacy Calendar configuration changed during profile preparation." }

  New-Item -ItemType Directory -Force -Path $configDir | Out-Null
  $stagePath = Join-Path $configDir (".calendar-read-" + [guid]::NewGuid().ToString("N") + ".tmp")
  try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($stagePath, $profile.Lines, $utf8NoBom)
    $stagedProfile = Get-ReadProfile -Path $stagePath
    if (
      $stagedProfile.GoogleCalendarCount -ne $profile.GoogleCalendarCount -or
      $stagedProfile.NextcloudCalendarCount -ne $profile.NextcloudCalendarCount
    ) {
      throw "Staged Calendar read profile did not validate."
    }
    Move-Item -LiteralPath $stagePath -Destination $readProfilePath
  } catch {
    Remove-Item -LiteralPath $stagePath -Force -ErrorAction SilentlyContinue
    throw
  }
  return $profile
}

$profileReady = Test-Path -LiteralPath $readProfilePath -PathType Leaf
$plannedProfile = $null
if ($InitializeReadProfile) {
  $plannedProfile = Get-ReadProfile -Path $legacyEnvPath
} elseif ($profileReady) {
  $plannedProfile = Get-ReadProfile -Path $readProfilePath
}

$plan = [ordered]@{
  component = $componentName
  repository = $repoRoot
  vaultAuthority = $resolvedVault
  obsidianVaultName = $ObsidianVaultName
  localState = $componentState
  credentialProfile = $readProfilePath
  profileReady = $profileReady
  initializeReadProfile = [bool]$InitializeReadProfile
  allowMarkdownFallback = [bool]$AllowMarkdownFallback
  legacyConfigSource = if ($InitializeReadProfile) { $legacyEnvPath } else { $null }
  includedKeys = if ($plannedProfile) { $plannedProfile.IncludedKeys } else { @() }
  googleCalendarCount = if ($plannedProfile) { $plannedProfile.GoogleCalendarCount } else { 0 }
  nextcloudCalendarCount = if ($plannedProfile) { $plannedProfile.NextcloudCalendarCount } else { 0 }
  oauthCredentialsCopied = $false
  oauthTokenCopied = $false
  writeTargetsCopied = $false
  publishingCredentialsCopied = $false
  port = $Port
  mode = $runtimeMode
  writeCapabilities = $writeCapabilities
  vaultWrites = [bool]$EnableVaultEventCreate
  remoteWrites = $false
  productionProcessChanged = $false
}
$plan | ConvertTo-Json -Depth 4
if (-not $Apply) {
  Write-Host "Plan only. Re-run with -Apply after reviewing the authorities, read profile, and port."
  exit 0
}

if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
  throw "Port $Port is already in use; no process was stopped."
}
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
  throw "A Calendar read process manifest already exists; use stop-calendar-read.ps1 first."
}
if (Test-Path -LiteralPath $pidPath -PathType Leaf) {
  throw "A Calendar preview PID file already exists; review it before starting."
}

if ($InitializeReadProfile) {
  $activeProfile = Initialize-ReadProfile
  $profileReady = $true
} elseif ($profileReady) {
  $activeProfile = Get-ReadProfile -Path $readProfilePath
} else {
  throw "Calendar read profile is not initialized. Review and apply once with -InitializeReadProfile."
}

foreach ($key in $blockedCredentialKeys) {
  Remove-Item -LiteralPath ("Env:" + $key) -ErrorAction SilentlyContinue
}
$env:NICA_VAULT_ROOT = $resolvedVault
$env:NICA_STATE_ROOT = $resolvedState
$env:NICA_WRITE_ENABLED = "false"
$env:NICA_CALENDAR_VAULT_CREATE_ENABLED = if ($EnableVaultEventCreate) { "true" } else { "false" }
$env:NICA_OBSIDIAN_ACTIONS_ENABLED = "false"
$env:NICA_CALENDAR_ENV_FILE = $readProfilePath
$env:OBSIDIAN_VAULT_NAME = $ObsidianVaultName
$env:ALLOW_MARKDOWN_FALLBACK = if ($AllowMarkdownFallback) { "true" } else { "false" }
$env:CALENDAR_HOST = "127.0.0.1"
$env:CALENDAR_PORT = [string]$Port

& node (Join-Path $calendarRoot "build-events.mjs")
if ($LASTEXITCODE -ne 0) { throw "Calendar derived-data build failed." }
if (-not (Test-Path -LiteralPath $generatedEventsPath -PathType Leaf)) {
  throw "Calendar derived event bundle is missing after build."
}
$generatedRaw = [System.IO.File]::ReadAllText($generatedEventsPath)
$generatedPrefix = "window.CALENDAR_EVENTS = "
if (-not $generatedRaw.StartsWith($generatedPrefix)) { throw "Calendar derived event bundle has an invalid format." }
$generatedEvents = $generatedRaw.Substring($generatedPrefix.Length).Trim().TrimEnd(';') | ConvertFrom-Json
$generatedEventCount = if ($null -eq $generatedEvents) {
  0
} elseif ($generatedEvents -is [System.Array]) {
  $generatedEvents.Count
} else {
  1
}

New-Item -ItemType Directory -Force -Path $componentState | Out-Null
$logPrefix = if ($EnableVaultEventCreate) { "calendar-vault-write" } else { "calendar-read" }
$stdout = Join-Path $componentState ($logPrefix + ".out.log")
$stderr = Join-Path $componentState ($logPrefix + ".err.log")
$serverPath = Join-Path $calendarRoot "serve.mjs"
$proc = $null
try {
  $proc = Start-Process -FilePath "node" -ArgumentList ('"' + $serverPath + '"') -WorkingDirectory $calendarRoot -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru

  $healthy = $false
  for ($attempt = 0; $attempt -lt 40; $attempt += 1) {
    try {
      $ping = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/ping" -TimeoutSec 1
      if (
        $ping.ok -and
        $ping.component -eq "calendar" -and
        $ping.mode -eq $runtimeMode -and
        [bool]$ping.writesEnabled -eq [bool]$EnableVaultEventCreate -and
        [bool]$ping.writeCapabilities.vaultEventCreate -eq [bool]$EnableVaultEventCreate -and
        -not [bool]$ping.writeCapabilities.unrestricted -and
        $ping.authority.vault -eq $resolvedVault -and
        $ping.authority.localState -eq $componentState
      ) {
        $healthy = $true
        break
      }
    } catch { }
    Start-Sleep -Milliseconds 250
  }
  if (-not $healthy) { throw "Calendar reader did not become healthy with the planned authority." }

  $googleConfig = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/google-calendar/config" -TimeoutSec 5
  $nextcloudConfig = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/nextcloud-calendar/config" -TimeoutSec 5
  $filters = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/calendar/filters" -TimeoutSec 5
  $themeReady = $false
  try {
    $theme = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/obsidian/theme" -TimeoutSec 5
    $themeReady = [bool]$theme.ok
  } catch {
    if (-not $AllowMarkdownFallback) { throw }
  }
  if (
    [bool]$googleConfig.oauth.configured -or
    [bool]$googleConfig.oauth.connected -or
    [bool]$googleConfig.oauth.writable -or
    [bool]$nextcloudConfig.writable
  ) {
    throw "Calendar reader exposed a write-capable external source."
  }
  if (
    @($googleConfig.calendars).Count -ne $activeProfile.GoogleCalendarCount -or
    @($nextcloudConfig.calendars).Count -ne $activeProfile.NextcloudCalendarCount -or
    -not $filters.ok -or
    (-not $AllowMarkdownFallback -and -not $themeReady)
  ) {
    throw "Calendar reader configuration did not match the planned read profile."
  }

  $rangeStart = [Uri]::EscapeDataString((Get-Date).AddYears(-1).ToUniversalTime().ToString("o"))
  $rangeEnd = [Uri]::EscapeDataString((Get-Date).AddYears(1).ToUniversalTime().ToString("o"))
  $googleReadStatus = if ($activeProfile.GoogleCalendarCount) { 0 } else { 204 }
  $googleEventCount = 0
  if ($activeProfile.GoogleCalendarCount) {
    for ($remoteAttempt = 0; $remoteAttempt -lt 3 -and $googleReadStatus -ne 200; $remoteAttempt += 1) {
      try {
        $googleEvents = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/google-calendar/events?start=$rangeStart&end=$rangeEnd" -TimeoutSec 30
        if ($googleEvents.ok) {
          $googleReadStatus = 200
          $googleEventCount = @($googleEvents.events).Count
        }
      } catch {
        $googleReadStatus = [int]$_.Exception.Response.StatusCode
        if (-not $googleReadStatus) { $googleReadStatus = 503 }
      }
      if ($googleReadStatus -ne 200) { Start-Sleep -Milliseconds 500 }
    }
  }

  $nextcloudReadStatus = if ($activeProfile.NextcloudCalendarCount) { 0 } else { 204 }
  $nextcloudEventCount = 0
  if ($activeProfile.NextcloudCalendarCount) {
    for ($remoteAttempt = 0; $remoteAttempt -lt 3 -and $nextcloudReadStatus -ne 200; $remoteAttempt += 1) {
      try {
        $nextcloudEvents = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/nextcloud-calendar/events?start=$rangeStart&end=$rangeEnd" -TimeoutSec 30
        if ($nextcloudEvents.ok) {
          $nextcloudReadStatus = 200
          $nextcloudEventCount = @($nextcloudEvents.events).Count
        }
      } catch {
        $nextcloudReadStatus = [int]$_.Exception.Response.StatusCode
        if (-not $nextcloudReadStatus) { $nextcloudReadStatus = 503 }
      }
      if ($nextcloudReadStatus -ne 200) { Start-Sleep -Milliseconds 500 }
    }
  }

  $writeStatus = 0
  try {
    Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$Port/api/events/rebuild" -ContentType "application/json" -Body "{}" -TimeoutSec 5 | Out-Null
    $writeStatus = 200
  } catch {
    $writeStatus = [int]$_.Exception.Response.StatusCode
  }
  $oauthStatus = 0
  try {
    Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/google-oauth/start" -TimeoutSec 5 | Out-Null
    $oauthStatus = 200
  } catch {
    $oauthStatus = [int]$_.Exception.Response.StatusCode
  }
  if ($writeStatus -ne 403 -or $oauthStatus -ne 403) {
    throw "Calendar reader did not block write or OAuth-change routes."
  }

  $manifest = [ordered]@{
    component = $componentName
    repository = $repoRoot
    vaultAuthority = $resolvedVault
    stateRoot = $resolvedState
    port = $Port
    mode = $runtimeMode
    writeCapabilities = $writeCapabilities
    localEventCount = $generatedEventCount
    googleCalendarCount = $activeProfile.GoogleCalendarCount
    googleReadStatus = $googleReadStatus
    googleEventCount = $googleEventCount
    nextcloudCalendarCount = $activeProfile.NextcloudCalendarCount
    nextcloudReadStatus = $nextcloudReadStatus
    nextcloudEventCount = $nextcloudEventCount
    pid = $proc.Id
    startedAt = (Get-Date).ToString("o")
    stdout = $stdout
    stderr = $stderr
  }
  $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding utf8
} catch {
  if ($proc) {
    Stop-Process -Id $proc.Id -ErrorAction SilentlyContinue
    Wait-Process -Id $proc.Id -Timeout 5 -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
  throw
}

$manifest | ConvertTo-Json -Depth 4
