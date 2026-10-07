[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$VaultRoot,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [string]$LegacyToolsRoot = "",
  [int]$Port = 4276,
  [switch]$RefreshSnapshot,
  [switch]$PrepareFetchProfile,
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
$resolvedLegacy = (Resolve-Path -LiteralPath $legacyRootInput).Path
$legacyEmailRoot = Join-Path $resolvedLegacy "Email"
$sourceDatabase = Join-Path $legacyEmailRoot "email.db"
$legacyConfigPath = Join-Path $legacyEmailRoot "config.local.json"

if (-not (Test-Path -LiteralPath $sourceDatabase -PathType Leaf)) {
  throw "Legacy Email database was not found."
}
if ($Port -lt 1 -or $Port -gt 65535) { throw "Port must be between 1 and 65535." }

$vaultPrefix = $resolvedVault.TrimEnd('\') + '\'
$statePrefix = $resolvedState.TrimEnd('\') + '\'
if (
  $resolvedVault -eq $resolvedState -or
  $resolvedState.StartsWith($vaultPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
  $resolvedVault.StartsWith($statePrefix, [System.StringComparison]::OrdinalIgnoreCase)
) {
  throw "VaultRoot and StateRoot must be separate directory trees."
}

function Resolve-ContainedFile {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [Parameter(Mandatory = $true)][string]$Label,
    [switch]$MustExist
  )

  if ([string]::IsNullOrWhiteSpace($RelativePath) -or [System.IO.Path]::IsPathRooted($RelativePath)) {
    throw "$Label must be a relative path."
  }
  $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
  $candidate = [System.IO.Path]::GetFullPath((Join-Path $rootPath $RelativePath))
  $prefix = $rootPath + '\'
  if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "$Label escaped its expected directory."
  }
  if ($MustExist -and -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    throw "$Label was not found."
  }
  return $candidate
}

function Copy-AtomicFile {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
  )

  $sourceItem = Get-Item -LiteralPath $Source
  if ($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    throw "Credential-profile sources must not be symbolic links or reparse points."
  }
  $destinationDirectory = Split-Path -Parent $Destination
  New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
  $staged = $Destination + ".stage-" + [Guid]::NewGuid().ToString("N")
  try {
    Copy-Item -LiteralPath $Source -Destination $staged
    Move-Item -LiteralPath $staged -Destination $Destination -Force
  } finally {
    Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
  }
}

function Test-SameDirectory {
  param(
    [Parameter(Mandatory = $true)][string]$Left,
    [Parameter(Mandatory = $true)][string]$Right
  )

  try {
    return (Get-Item -LiteralPath $Left).FullName -eq (Get-Item -LiteralPath $Right).FullName
  } catch {
    return $false
  }
}

$componentState = Join-Path $resolvedState "email"
$candidateDatabase = Join-Path $componentState "email.db"
$candidateConfigPath = Join-Path $componentState "config.local.json"
$profileFiles = @()
$oauthTokenFiles = @()
$accountCount = 0

if ($PrepareFetchProfile) {
  if (-not (Test-Path -LiteralPath $legacyConfigPath -PathType Leaf)) {
    throw "Legacy Email configuration was not found."
  }
  $legacyConfig = Get-Content -LiteralPath $legacyConfigPath -Raw | ConvertFrom-Json
  $accounts = @($legacyConfig.accounts)
  $accountCount = $accounts.Count
  $profileFiles += [pscustomobject]@{
    source = $legacyConfigPath
    destination = $candidateConfigPath
  }
  foreach ($envName in @(".env", ".env.local")) {
    $sourceEnv = Join-Path $legacyEmailRoot $envName
    if (Test-Path -LiteralPath $sourceEnv -PathType Leaf) {
      $profileFiles += [pscustomobject]@{
        source = $sourceEnv
        destination = Join-Path $componentState $envName
      }
    }
  }
  foreach ($account in $accounts) {
    $authMethod = if ($null -ne $account.auth) { [string]$account.auth.method } else { "" }
    if ($authMethod.ToLowerInvariant() -ne "oauth") { continue }
    $tokenRelative = [string]$account.oauthTokenPath
    if ([string]::IsNullOrWhiteSpace($tokenRelative)) {
      $tokenRelative = ([string]$account.id) + ".json"
    }
    $tokenSource = Resolve-ContainedFile -Root $legacyEmailRoot -RelativePath $tokenRelative -Label "Legacy OAuth token" -MustExist
    $tokenDestination = Resolve-ContainedFile -Root $componentState -RelativePath $tokenRelative -Label "Candidate OAuth token"
    $oauthTokenFiles += [pscustomobject]@{
      source = $tokenSource
      destination = $tokenDestination
    }
  }
}

$sourceInfo = Get-Item -LiteralPath $sourceDatabase
$plan = [ordered]@{
  component = "email-fetch-shadow"
  repository = $repoRoot
  vaultAuthority = $resolvedVault
  localState = $componentState
  sourceDatabaseBytes = $sourceInfo.Length
  sourceWalPresent = Test-Path -LiteralPath ($sourceDatabase + "-wal") -PathType Leaf
  sourceShmPresent = Test-Path -LiteralPath ($sourceDatabase + "-shm") -PathType Leaf
  snapshotAction = if ($RefreshSnapshot) { "consistent-sqlite-backup" } else { "retain-existing" }
  snapshotReady = Test-Path -LiteralPath $candidateDatabase -PathType Leaf
  profileAction = if ($PrepareFetchProfile) { "copy-to-isolated-local-state" } else { "retain-existing" }
  profileReady = Test-Path -LiteralPath $candidateConfigPath -PathType Leaf
  configuredAccountCount = $accountCount
  credentialEnvironmentFileCount = @($profileFiles | Where-Object { (Split-Path -Leaf $_.source) -like ".env*" }).Count
  oauthTokenFileCount = $oauthTokenFiles.Count
  writeCapabilities = @("mail.count", "mail.fetch")
  oauthSetupEnabled = $false
  rulesEnabled = $false
  messageTaggingEnabled = $false
  vaultExportEnabled = $false
  imapMailboxMode = "read-only"
  port = $Port
  mode = "limited-write"
  legacyProcessChanged = $false
}
$plan | ConvertTo-Json -Depth 4
if (-not $Apply) {
  Write-Host "Plan only. Re-run with -Apply after reviewing the isolated state, credential-profile counts, capabilities, and port."
  exit 0
}

$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($listener) { throw "Port $Port is already in use; no process was stopped." }

New-Item -ItemType Directory -Force -Path $componentState | Out-Null
$componentState = (Resolve-Path -LiteralPath $componentState).Path
$candidateDatabase = Join-Path $componentState "email.db"
$candidateConfigPath = Join-Path $componentState "config.local.json"

if ($PrepareFetchProfile) {
  foreach ($file in @($profileFiles) + @($oauthTokenFiles)) {
    Copy-AtomicFile -Source $file.source -Destination $file.destination
  }
  Get-Content -LiteralPath $candidateConfigPath -Raw | ConvertFrom-Json | Out-Null
}
if ($RefreshSnapshot) {
  & python (Join-Path $repoRoot "Email\snapshot_db.py") --source $sourceDatabase --destination $candidateDatabase
  if ($LASTEXITCODE -ne 0) { throw "Consistent Email database snapshot failed." }
}
if (-not (Test-Path -LiteralPath $candidateDatabase -PathType Leaf)) {
  throw "Email snapshot is not initialized. Re-run with -RefreshSnapshot -Apply."
}
if (-not (Test-Path -LiteralPath $candidateConfigPath -PathType Leaf)) {
  throw "Email fetch profile is not initialized. Re-run with -PrepareFetchProfile -Apply."
}

$env:NICA_VAULT_ROOT = $resolvedVault
$env:NICA_STATE_ROOT = $resolvedState
$env:NICA_WRITE_ENABLED = "false"
$env:NICA_EMAIL_CAPABILITIES = "mail.count,mail.fetch"
$env:EMAIL_HOST = "127.0.0.1"
$env:EMAIL_PORT = [string]$Port

$stdout = Join-Path $componentState "email-fetch.out.log"
$stderr = Join-Path $componentState "email-fetch.err.log"
$serverPath = Join-Path $repoRoot "Email\email_tool.py"
$proc = Start-Process -FilePath "python" -ArgumentList ('"' + $serverPath + '" serve') -WorkingDirectory (Join-Path $repoRoot "Email") -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
$manifestPath = Join-Path $componentState "email-read-process.json"
$manifest = [ordered]@{
  component = "email-fetch-shadow"
  repository = $repoRoot
  vaultAuthority = $resolvedVault
  stateRoot = $resolvedState
  port = $Port
  mode = "limited-write"
  writeCapabilities = @("mail.count", "mail.fetch")
  snapshotRefreshed = [bool]$RefreshSnapshot
  fetchProfilePrepared = [bool]$PrepareFetchProfile
  pid = $proc.Id
  startedAt = (Get-Date).ToString("o")
  stdout = $stdout
  stderr = $stderr
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding utf8

try {
  $healthy = $false
  $lastHealth = $null
  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    try {
      $response = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/ping" -TimeoutSec 1
      $lastHealth = $response
      if (
        $response.ok -and
        $response.component -eq "email" -and
        $response.mode -eq "limited-write" -and
        [bool]$response.writesEnabled -and
        -not [bool]$response.writeCapabilities.unrestricted -and
        [bool]$response.writeCapabilities.mailCount -and
        [bool]$response.writeCapabilities.mailFetch -and
        -not [bool]$response.writeCapabilities.oauthManage -and
        -not [bool]$response.writeCapabilities.rulesManage -and
        -not [bool]$response.writeCapabilities.rulesApply -and
        -not [bool]$response.writeCapabilities.messageTag -and
        -not [bool]$response.writeCapabilities.vaultExport -and
        (Test-SameDirectory -Left $response.authority.vault -Right $resolvedVault) -and
        (Test-SameDirectory -Left $response.authority.localState -Right $componentState)
      ) {
        $healthy = $true
        break
      }
    } catch { }
    Start-Sleep -Milliseconds 250
  }
  if (-not $healthy) {
    if ($null -ne $lastHealth) {
      $diagnostic = [ordered]@{
        component = $lastHealth.component
        mode = $lastHealth.mode
        writesEnabled = $lastHealth.writesEnabled
        writeCapabilities = $lastHealth.writeCapabilities
        vaultMatches = (Test-SameDirectory -Left $lastHealth.authority.vault -Right $resolvedVault)
        stateMatches = (Test-SameDirectory -Left $lastHealth.authority.localState -Right $componentState)
      }
      Write-Error ($diagnostic | ConvertTo-Json -Depth 4)
    }
    throw "Email fetch shadow did not become healthy with the planned authority and capabilities."
  }

  foreach ($route in @("export", "rules", "rules/apply", "messages/tag", "oauth/start")) {
    try {
      Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/$route" -Method Post -ContentType "application/json" -Body "{}" -UseBasicParsing | Out-Null
      throw "Email route $route unexpectedly accepted a disabled request."
    } catch {
      if ([int]$_.Exception.Response.StatusCode -ne 403) { throw }
    }
  }
} catch {
  Stop-Process -Id $proc.Id -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $componentState "email.preview.pid") -Force -ErrorAction SilentlyContinue
  throw
}

$manifest | ConvertTo-Json -Depth 4
