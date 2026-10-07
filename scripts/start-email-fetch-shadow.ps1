[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$VaultRoot,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [string]$LegacyToolsRoot = "",
  [int]$Port = 4276,
  [int]$HomepagePort = 4274,
  [switch]$RefreshSnapshot,
  [switch]$InitializeFreshDatabase,
  [switch]$PrepareFetchProfile,
  [switch]$EnableClassification,
  [switch]$EnableOAuth,
  [switch]$EnableExport,
  [switch]$BackupCandidate,
  [switch]$RefreshCandidateBackup,
  [switch]$StableRuntime,
  [int]$OAuthCallbackPort = 8080,
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedVault = (Resolve-Path -LiteralPath $VaultRoot).Path
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)
$resolvedLegacy = $null
$legacyEmailRoot = $null
$sourceDatabase = $null
$legacyConfigPath = $null
$requiresLegacyRoot = $RefreshSnapshot -or $PrepareFetchProfile
if ($requiresLegacyRoot) {
  $legacyRootInput = if ([string]::IsNullOrWhiteSpace($LegacyToolsRoot)) {
    Join-Path $resolvedVault "Tools"
  } else {
    $LegacyToolsRoot
  }
  $resolvedLegacy = (Resolve-Path -LiteralPath $legacyRootInput).Path
  $legacyEmailRoot = Join-Path $resolvedLegacy "Email"
  $sourceDatabase = Join-Path $legacyEmailRoot "email.db"
  $legacyConfigPath = Join-Path $legacyEmailRoot "config.local.json"
}
$componentName = if ($StableRuntime) { "email" } elseif ($EnableExport) { "email-export-shadow" } elseif ($EnableOAuth) { "email-oauth-shadow" } elseif ($EnableClassification) { "email-classification-shadow" } else { "email-fetch-shadow" }
$writeCapabilities = @("mail.count", "mail.fetch")
if ($EnableClassification) {
  $writeCapabilities += @("message.tag", "rules.apply", "rules.manage")
}
if ($EnableOAuth) { $writeCapabilities += "oauth.manage" }
if ($EnableExport) { $writeCapabilities += "vault.export" }

if ($RefreshSnapshot -and -not (Test-Path -LiteralPath $sourceDatabase -PathType Leaf)) {
  throw "Legacy Email database was not found."
}
if ($RefreshSnapshot -and $InitializeFreshDatabase) {
  throw "RefreshSnapshot and InitializeFreshDatabase are mutually exclusive."
}
if ($Port -lt 1 -or $Port -gt 65535) { throw "Port must be between 1 and 65535." }
if ($HomepagePort -lt 1 -or $HomepagePort -gt 65535) { throw "HomepagePort must be between 1 and 65535." }
if ($OAuthCallbackPort -lt 1 -or $OAuthCallbackPort -gt 65535) { throw "OAuth callback port must be between 1 and 65535." }
if ($EnableOAuth -and -not $EnableClassification) {
  throw "The OAuth profile must retain the accepted classification capabilities."
}
if ($EnableExport -and -not $EnableOAuth) {
  throw "The export profile must retain the accepted OAuth capabilities."
}
if (($BackupCandidate -or $RefreshCandidateBackup) -and -not $EnableClassification) {
  throw "Candidate backup is supported only for the classification profile."
}
if ($InitializeFreshDatabase -and ($BackupCandidate -or $RefreshCandidateBackup)) {
  throw "A fresh Email database cannot also use a candidate-database backup action."
}
if ($Port -eq $HomepagePort -or ($EnableOAuth -and $OAuthCallbackPort -in @($Port, $HomepagePort))) {
  throw "Email, Homepage, and enabled OAuth callback ports must be different."
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
    [Parameter(Mandatory = $true)][string]$Destination,
    [switch]$NoOverwrite
  )

  $sourceItem = Get-Item -LiteralPath $Source
  if ($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    throw "Backup and credential-profile sources must not be symbolic links or reparse points."
  }
  $destinationDirectory = Split-Path -Parent $Destination
  New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
  $staged = $Destination + ".stage-" + [Guid]::NewGuid().ToString("N")
  try {
    Copy-Item -LiteralPath $Source -Destination $staged
    if ($NoOverwrite) {
      [System.IO.File]::Move($staged, $Destination)
    } else {
      Move-Item -LiteralPath $staged -Destination $Destination -Force
    }
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
$rollbackDatabase = Join-Path $componentState "backups\email-before-classification.db"
$originalRollbackDatabase = Join-Path $componentState "backups\email-before-classification.original.db"
$candidateBackupExists = Test-Path -LiteralPath $rollbackDatabase -PathType Leaf
$candidateBackupAction = if ($RefreshCandidateBackup) {
  if ($candidateBackupExists) { "preserve-original-and-refresh" } else { "create" }
} elseif ($BackupCandidate) {
  if ($candidateBackupExists) { "retain-existing" } else { "create" }
} else {
  "none"
}
$profileFiles = @()
$oauthTokenFiles = @()
$candidateOauthTokens = @()
$accountCount = 0
$credentialEnvironmentFileCount = 0
$oauthTokenFileCount = 0

if ($InitializeFreshDatabase -and (Test-Path -LiteralPath $candidateDatabase)) {
  throw "Fresh Email initialization requires an empty database path; the existing database was not changed."
}

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
    $candidateOauthTokens += [pscustomobject]@{
      relative = $tokenRelative
      path = $tokenDestination
    }
  }
  $credentialEnvironmentFileCount = @($profileFiles | Where-Object { (Split-Path -Leaf $_.source) -like ".env*" }).Count
  $oauthTokenFileCount = $oauthTokenFiles.Count
} elseif (Test-Path -LiteralPath $candidateConfigPath -PathType Leaf) {
  $candidateConfig = Get-Content -LiteralPath $candidateConfigPath -Raw | ConvertFrom-Json
  $candidateAccounts = @($candidateConfig.accounts)
  $accountCount = $candidateAccounts.Count
  $credentialEnvironmentFileCount = @(
    @(".env", ".env.local") | Where-Object { Test-Path -LiteralPath (Join-Path $componentState $_) -PathType Leaf }
  ).Count
  foreach ($account in $candidateAccounts) {
    $authMethod = if ($null -ne $account.auth) { [string]$account.auth.method } else { "" }
    if ($authMethod.ToLowerInvariant() -ne "oauth") { continue }
    $tokenRelative = [string]$account.oauthTokenPath
    if ([string]::IsNullOrWhiteSpace($tokenRelative)) {
      $tokenRelative = ([string]$account.id) + ".json"
    }
    $tokenPath = Resolve-ContainedFile -Root $componentState -RelativePath $tokenRelative -Label "Candidate OAuth token"
    $candidateOauthTokens += [pscustomobject]@{
      relative = $tokenRelative
      path = $tokenPath
    }
    if (Test-Path -LiteralPath $tokenPath -PathType Leaf) {
      $oauthTokenFileCount++
    }
  }
}

$oauthBackupRoot = Join-Path $componentState "backups\oauth-before-management"
$oauthTokenBackupReadyCount = 0
foreach ($token in $candidateOauthTokens) {
  $backupPath = Resolve-ContainedFile -Root $oauthBackupRoot -RelativePath $token.relative -Label "Candidate OAuth token backup"
  $tokenWillExist = $PrepareFetchProfile -or (Test-Path -LiteralPath $token.path -PathType Leaf)
  if ($tokenWillExist -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
    $oauthTokenBackupReadyCount++
  }
}
$oauthTokenBackupAction = if ($EnableOAuth -and $oauthTokenFileCount -gt $oauthTokenBackupReadyCount) {
  "create-missing"
} elseif ($EnableOAuth -and $oauthTokenFileCount -gt 0) {
  "retain-existing"
} else {
  "none"
}

$sourceInfo = if ($RefreshSnapshot) { Get-Item -LiteralPath $sourceDatabase } else { $null }
$plan = [ordered]@{
  component = $componentName
  repository = $repoRoot
  vaultAuthority = $resolvedVault
  localState = $componentState
  sourceDatabaseBytes = if ($null -ne $sourceInfo) { $sourceInfo.Length } else { $null }
  sourceWalPresent = [bool]($RefreshSnapshot -and (Test-Path -LiteralPath ($sourceDatabase + "-wal") -PathType Leaf))
  sourceShmPresent = [bool]($RefreshSnapshot -and (Test-Path -LiteralPath ($sourceDatabase + "-shm") -PathType Leaf))
  databaseAction = if ($InitializeFreshDatabase) { "initialize-empty" } elseif ($RefreshSnapshot) { "consistent-sqlite-backup" } else { "retain-existing" }
  snapshotAction = if ($RefreshSnapshot) { "consistent-sqlite-backup" } elseif ($InitializeFreshDatabase) { "not-used" } else { "retain-existing" }
  snapshotReady = Test-Path -LiteralPath $candidateDatabase -PathType Leaf
  candidateBackupAction = $candidateBackupAction
  candidateBackupReady = $candidateBackupExists
  originalCandidateBackupReady = Test-Path -LiteralPath $originalRollbackDatabase -PathType Leaf
  profileAction = if ($PrepareFetchProfile) { "copy-to-isolated-local-state" } else { "retain-existing" }
  profileReady = Test-Path -LiteralPath $candidateConfigPath -PathType Leaf
  configuredAccountCount = $accountCount
  credentialEnvironmentFileCount = $credentialEnvironmentFileCount
  oauthTokenFileCount = $oauthTokenFileCount
  oauthTokenBackupAction = $oauthTokenBackupAction
  oauthTokenBackupReadyCount = $oauthTokenBackupReadyCount
  writeCapabilities = $writeCapabilities
  oauthSetupEnabled = [bool]$EnableOAuth
  oauthCallbackPort = $OAuthCallbackPort
  rulesEnabled = [bool]$EnableClassification
  messageTaggingEnabled = [bool]$EnableClassification
  vaultExportEnabled = [bool]$EnableExport
  imapMailboxMode = "read-only"
  port = $Port
  homepagePort = $HomepagePort
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
if ($EnableOAuth) {
  $oauthListener = Get-NetTCPConnection -LocalPort $OAuthCallbackPort -State Listen -ErrorAction SilentlyContinue
  if ($oauthListener) { throw "OAuth callback port $OAuthCallbackPort is already in use; no process was stopped." }
}

New-Item -ItemType Directory -Force -Path $componentState | Out-Null
$componentState = (Resolve-Path -LiteralPath $componentState).Path
$candidateDatabase = Join-Path $componentState "email.db"
$candidateConfigPath = Join-Path $componentState "config.local.json"
$rollbackDatabase = Join-Path $componentState "backups\email-before-classification.db"
$originalRollbackDatabase = Join-Path $componentState "backups\email-before-classification.original.db"
$candidateBackupCreated = $false
$candidateBackupRefreshed = $false
$originalCandidateBackupCreated = $false

if ($BackupCandidate -or $RefreshCandidateBackup) {
  if (-not (Test-Path -LiteralPath $candidateDatabase -PathType Leaf)) {
    throw "Candidate Email database is not initialized; no classification rollback snapshot was created."
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $rollbackDatabase) | Out-Null
  $rollbackExists = Test-Path -LiteralPath $rollbackDatabase -PathType Leaf
  if ($RefreshCandidateBackup -and $rollbackExists) {
    if (-not (Test-Path -LiteralPath $originalRollbackDatabase -PathType Leaf)) {
      Copy-AtomicFile -Source $rollbackDatabase -Destination $originalRollbackDatabase -NoOverwrite
      $originalCandidateBackupCreated = $true
    }
    & python (Join-Path $repoRoot "Email\snapshot_db.py") --source $candidateDatabase --destination $rollbackDatabase
    if ($LASTEXITCODE -ne 0) { throw "Candidate Email rollback snapshot refresh failed." }
    $candidateBackupCreated = $true
    $candidateBackupRefreshed = $true
  } elseif (-not $rollbackExists) {
    & python (Join-Path $repoRoot "Email\snapshot_db.py") --source $candidateDatabase --destination $rollbackDatabase
    if ($LASTEXITCODE -ne 0) { throw "Candidate Email rollback snapshot failed." }
    $candidateBackupCreated = $true
  }
}

if ($PrepareFetchProfile) {
  foreach ($file in @($profileFiles) + @($oauthTokenFiles)) {
    Copy-AtomicFile -Source $file.source -Destination $file.destination
  }
  Get-Content -LiteralPath $candidateConfigPath -Raw | ConvertFrom-Json | Out-Null
}
$oauthTokenBackupsCreated = 0
if ($EnableOAuth) {
  foreach ($token in $candidateOauthTokens) {
    if (-not (Test-Path -LiteralPath $token.path -PathType Leaf)) {
      continue
    }
    $backupPath = Resolve-ContainedFile -Root $oauthBackupRoot -RelativePath $token.relative -Label "Candidate OAuth token backup"
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
      Copy-AtomicFile -Source $token.path -Destination $backupPath -NoOverwrite
      $oauthTokenBackupsCreated++
    }
  }
}
if ($RefreshSnapshot) {
  & python (Join-Path $repoRoot "Email\snapshot_db.py") --source $sourceDatabase --destination $candidateDatabase
  if ($LASTEXITCODE -ne 0) { throw "Consistent Email database snapshot failed." }
}
if (-not $InitializeFreshDatabase -and -not (Test-Path -LiteralPath $candidateDatabase -PathType Leaf)) {
  throw "Email database is not initialized. Use -InitializeFreshDatabase or -RefreshSnapshot with -Apply."
}
if (-not (Test-Path -LiteralPath $candidateConfigPath -PathType Leaf)) {
  throw "Email fetch profile is not initialized. Re-run with -PrepareFetchProfile -Apply."
}

$env:NICA_VAULT_ROOT = $resolvedVault
$env:NICA_STATE_ROOT = $resolvedState
$env:NICA_WRITE_ENABLED = "false"
$env:NICA_EMAIL_CAPABILITIES = $writeCapabilities -join ","
$env:EMAIL_HOST = "127.0.0.1"
$env:EMAIL_PORT = [string]$Port
$env:EMAIL_OAUTH_CALLBACK_PORT = [string]$OAuthCallbackPort
$env:NICA_HOMEPAGE_URL = "http://127.0.0.1:$HomepagePort"

$logPrefix = if ($StableRuntime) { "email" } elseif ($EnableExport) { "email-export" } elseif ($EnableOAuth) { "email-oauth" } elseif ($EnableClassification) { "email-classification" } else { "email-fetch" }
$stdout = Join-Path $componentState ($logPrefix + ".out.log")
$stderr = Join-Path $componentState ($logPrefix + ".err.log")
$serverPath = Join-Path $repoRoot "Email\email_tool.py"
$proc = Start-Process -FilePath "python" -ArgumentList ('"' + $serverPath + '" serve') -WorkingDirectory (Join-Path $repoRoot "Email") -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
$manifestPath = Join-Path $componentState "email-read-process.json"
$manifest = [ordered]@{
  component = $componentName
  repository = $repoRoot
  vaultAuthority = $resolvedVault
  stateRoot = $resolvedState
  port = $Port
  homepagePort = $HomepagePort
  mode = "limited-write"
  writeCapabilities = $writeCapabilities
  databaseInitializedFresh = [bool]$InitializeFreshDatabase
  snapshotRefreshed = [bool]$RefreshSnapshot
  fetchProfilePrepared = [bool]$PrepareFetchProfile
  classificationEnabled = [bool]$EnableClassification
  oauthManagementEnabled = [bool]$EnableOAuth
  vaultExportEnabled = [bool]$EnableExport
  oauthCallbackPort = $OAuthCallbackPort
  oauthTokenBackupsCreated = $oauthTokenBackupsCreated
  candidateBackupCreated = $candidateBackupCreated
  candidateBackupRefreshed = $candidateBackupRefreshed
  candidateBackup = if ($BackupCandidate -or $RefreshCandidateBackup) { $rollbackDatabase } else { $null }
  originalCandidateBackupCreated = $originalCandidateBackupCreated
  originalCandidateBackup = if (Test-Path -LiteralPath $originalRollbackDatabase -PathType Leaf) { $originalRollbackDatabase } else { $null }
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
        ([bool]$response.writeCapabilities.oauthManage -eq [bool]$EnableOAuth) -and
        ([int]$response.oauthCallback.port -eq $OAuthCallbackPort) -and
        ([bool]$response.writeCapabilities.rulesManage -eq [bool]$EnableClassification) -and
        ([bool]$response.writeCapabilities.rulesApply -eq [bool]$EnableClassification) -and
        ([bool]$response.writeCapabilities.messageTag -eq [bool]$EnableClassification) -and
        ([bool]$response.writeCapabilities.vaultExport -eq [bool]$EnableExport) -and
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
    throw "$componentName did not become healthy with the planned authority and capabilities."
  }
  if ($InitializeFreshDatabase -and -not (Test-Path -LiteralPath $candidateDatabase -PathType Leaf)) {
    throw "Email service did not create the planned fresh database."
  }

  $disabledRoutes = @()
  if (-not $EnableExport) {
    $disabledRoutes += @("export", "export/plan", "export/apply")
  }
  if (-not $EnableOAuth) {
    $disabledRoutes += @("oauth/start", "oauth/poll")
  }
  if (-not $EnableClassification) {
    $disabledRoutes += @("rules", "rules/apply", "messages/tag")
  }
  foreach ($route in $disabledRoutes) {
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
  if ($InitializeFreshDatabase) {
    foreach ($databaseArtifact in @($candidateDatabase, $candidateDatabase + "-wal", $candidateDatabase + "-shm")) {
      Remove-Item -LiteralPath $databaseArtifact -Force -ErrorAction SilentlyContinue
    }
  }
  throw
}

$manifest | ConvertTo-Json -Depth 4
