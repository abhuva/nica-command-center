[CmdletBinding()]
param(
  [string]$SandboxRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\beantime-shadow"),
  [int]$HomepagePort = 4374,
  [int]$FavaPort = 4464,
  [switch]$EnableTimer,
  [switch]$EnableAppend,
  [switch]$EnableFava,
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedSandbox = [System.IO.Path]::GetFullPath($SandboxRoot)
$repoPrefix = $repoRoot.TrimEnd('\') + '\'
if (
  $resolvedSandbox -eq $repoRoot -or
  $resolvedSandbox.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)
) {
  throw "The synthetic Beantime sandbox must be outside the repository."
}
if ($HomepagePort -lt 1 -or $HomepagePort -gt 65535) {
  throw "HomepagePort must be between 1 and 65535."
}
if ($FavaPort -lt 1 -or $FavaPort -gt 65535) {
  throw "FavaPort must be between 1 and 65535."
}
if ($HomepagePort -eq $FavaPort) { throw "HomepagePort and FavaPort must be different." }
if ($EnableAppend -and -not $EnableTimer) {
  throw "Ledger append requires the timer capability because stop performs both operations."
}

$vaultRoot = Join-Path $resolvedSandbox "vault"
$stateRoot = Join-Path $resolvedSandbox "state"
$componentState = Join-Path $stateRoot "homepage"
$configDir = Join-Path $componentState "config"
$settingsPath = Join-Path $configDir "settings.local.json"
$ledgerPath = Join-Path $componentState "beantime\zeit.beancount"
$timerStatePath = Join-Path $componentState "beantime\state.json"
$manifestPath = Join-Path $componentState "beantime-shadow-process.json"
$templatePath = Join-Path $repoRoot "beantime\zeit.beancount"
$capabilities = @("beantime.read")
if ($EnableTimer) { $capabilities += "beantime.timer" }
if ($EnableAppend) { $capabilities += "beantime.append" }
if ($EnableFava) { $capabilities += "beantime.fava" }
$expectedMode = if ($EnableTimer -or $EnableAppend -or $EnableFava) { "limited-write" } else { "read-only" }

$plan = [ordered]@{
  component = "beantime-synthetic-shadow"
  repository = $repoRoot
  synthetic = $true
  vaultAuthority = $vaultRoot
  stateRoot = $stateRoot
  ledger = $ledgerPath
  timerState = $timerStatePath
  homepagePort = $HomepagePort
  favaPort = $FavaPort
  mode = $expectedMode
  capabilities = $capabilities
  liveLedgerAccess = $false
  productionProcessesChanged = $false
}
$plan | ConvertTo-Json -Depth 4
if (-not $Apply) {
  Write-Host "Plan only. Re-run with -Apply after reviewing the synthetic paths, ports, and capabilities."
  exit 0
}

if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
  throw "A Beantime shadow process manifest already exists; use stop-beantime-shadow.ps1 first."
}
if (Get-NetTCPConnection -LocalPort $HomepagePort -State Listen -ErrorAction SilentlyContinue) {
  throw "Homepage port $HomepagePort is already in use; no process was stopped."
}
if ($EnableFava -and (Get-NetTCPConnection -LocalPort $FavaPort -State Listen -ErrorAction SilentlyContinue)) {
  throw "Fava port $FavaPort is already in use; no process was stopped."
}
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
  throw "The tracked synthetic Beantime template is missing."
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  $staged = $Path + ".stage-" + [Guid]::NewGuid().ToString("N")
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  try {
    [System.IO.File]::WriteAllText(
      $staged,
      (($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine),
      $utf8NoBom
    )
    Move-Item -LiteralPath $staged -Destination $Path -Force
  } finally {
    Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
  }
}

New-Item -ItemType Directory -Force -Path (Join-Path $vaultRoot ".obsidian") | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ledgerPath) | Out-Null
if (-not (Test-Path -LiteralPath (Join-Path $vaultRoot ".obsidian\bookmarks.json") -PathType Leaf)) {
  Write-JsonFile -Path (Join-Path $vaultRoot ".obsidian\bookmarks.json") -Value ([ordered]@{ items = @() })
}

$syntheticSettings = [ordered]@{
  schemaVersion = 1
  ui = [ordered]@{ title = "Beantime Synthetic Shadow" }
  modules = [ordered]@{
    bookmarks = [ordered]@{ enabled = $false }
    clock = [ordered]@{ enabled = $false }
    newProject = [ordered]@{ enabled = $false }
    beantime = [ordered]@{
      enabled = $true
      title = "Beantime (synthetic)"
      file = "beantime/zeit.beancount"
      personAccount = "Zeit:Example"
      stateFile = "beantime/state.json"
      bookableAccountPrefix = "Projekte:"
    }
    vaultGraph = [ordered]@{ enabled = $false }
    email = [ordered]@{ enabled = $false }
    updo = [ordered]@{ enabled = $false }
  }
}
if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
  $existingSettings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
  $enabledModules = @(
    $existingSettings.modules.psobject.Properties |
      Where-Object { [bool]$_.Value.enabled } |
      ForEach-Object { $_.Name }
  )
  if (
    $enabledModules.Count -ne 1 -or
    $enabledModules[0] -ne "beantime" -or
    [string]$existingSettings.modules.beantime.file -ne "beantime/zeit.beancount" -or
    [string]$existingSettings.modules.beantime.stateFile -ne "beantime/state.json"
  ) {
    throw "Existing shadow settings are not the recognized synthetic Beantime profile."
  }
} else {
  Write-JsonFile -Path $settingsPath -Value $syntheticSettings
}
if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) {
  [System.IO.File]::Copy($templatePath, $ledgerPath, $false)
}

$resolvedVault = (Resolve-Path -LiteralPath $vaultRoot).Path
$resolvedState = (Resolve-Path -LiteralPath $stateRoot).Path
$resolvedComponentState = (Resolve-Path -LiteralPath $componentState).Path
$ledgerHash = (Get-FileHash -LiteralPath $ledgerPath -Algorithm SHA256).Hash.ToLowerInvariant()

$env:NICA_VAULT_ROOT = $resolvedVault
$env:NICA_STATE_ROOT = $resolvedState
$env:NICA_WRITE_ENABLED = "false"
$env:NICA_PROJECT_CREATE_ENABLED = "false"
$env:NICA_OBSIDIAN_ACTIONS_ENABLED = "false"
$env:NICA_BEANTIME_CAPABILITIES = $capabilities -join ","
$env:OBSIDIAN_VAULT_NAME = "synthetic-beantime-vault"
$env:HOMEPAGE_HOST = "127.0.0.1"
$env:HOMEPAGE_PORT = [string]$HomepagePort
$env:BEANTIME_FAVA_PORT = [string]$FavaPort

$stdout = Join-Path $componentState "beantime-shadow.out.log"
$stderr = Join-Path $componentState "beantime-shadow.err.log"
$serverPath = Join-Path $repoRoot "serve.mjs"
$proc = $null
try {
  $proc = Start-Process -FilePath "node" -ArgumentList ('"' + $serverPath + '"') -WorkingDirectory $repoRoot -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
  $manifest = [ordered]@{
    component = "beantime-synthetic-shadow"
    repository = $repoRoot
    synthetic = $true
    vaultAuthority = $resolvedVault
    stateRoot = $resolvedState
    componentState = $resolvedComponentState
    ledger = $ledgerPath
    ledgerSha256AtStart = $ledgerHash
    timerState = $timerStatePath
    homepagePort = $HomepagePort
    favaPort = $FavaPort
    mode = $expectedMode
    capabilities = $capabilities
    obsidianActionsEnabled = $false
    liveLedgerAccess = $false
    productionProcessesChanged = $false
    pid = $proc.Id
    startedAt = (Get-Date).ToString("o")
    stdout = $stdout
    stderr = $stderr
  }
  Write-JsonFile -Path $manifestPath -Value $manifest

  $healthy = $false
  for ($attempt = 0; $attempt -lt 60; $attempt += 1) {
    try {
      $health = Invoke-RestMethod -Uri "http://127.0.0.1:$HomepagePort/api/ping" -TimeoutSec 1
      $meta = Invoke-RestMethod -Uri "http://127.0.0.1:$HomepagePort/api/beantime/meta" -TimeoutSec 1
      if (
        $health.ok -and
        $health.component -eq "homepage" -and
        $health.mode -eq $expectedMode -and
        -not [bool]$health.writeCapabilities.unrestricted -and
        [bool]$health.writeCapabilities.beantimeRead -and
        ([bool]$health.writeCapabilities.beantimeTimer -eq [bool]$EnableTimer) -and
        ([bool]$health.writeCapabilities.beantimeAppend -eq [bool]$EnableAppend) -and
        ([bool]$health.writeCapabilities.beantimeFava -eq [bool]$EnableFava) -and
        $health.authority.vault -eq $resolvedVault -and
        $health.authority.localState -eq $resolvedComponentState -and
        $meta.ok -and
        $meta.file -eq "beantime/zeit.beancount" -and
        @($meta.accounts).Count -gt 0 -and
        @($meta.personAccounts).Count -gt 0
      ) {
        $healthy = $true
        break
      }
    } catch { }
    Start-Sleep -Milliseconds 250
  }
  if (-not $healthy) {
    throw "Beantime synthetic shadow did not become healthy with the planned authority and capabilities."
  }

  $disabledRoutes = @()
  if (-not $EnableTimer) { $disabledRoutes += "start" }
  if (-not ($EnableTimer -and $EnableAppend)) { $disabledRoutes += "stop" }
  if (-not $EnableFava) { $disabledRoutes += "show" }
  foreach ($route in $disabledRoutes) {
    try {
      Invoke-WebRequest -Uri "http://127.0.0.1:$HomepagePort/api/beantime/$route" -Method Post -ContentType "application/json" -Body "{}" -UseBasicParsing | Out-Null
      throw "Beantime route $route unexpectedly accepted a disabled request."
    } catch {
      if ([int]$_.Exception.Response.StatusCode -ne 403) { throw }
    }
  }
} catch {
  if ($proc) { Stop-Process -Id $proc.Id -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
  throw
}

$manifest | ConvertTo-Json -Depth 4
