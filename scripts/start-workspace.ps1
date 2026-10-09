[CmdletBinding()]
param(
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [switch]$Apply,
  [switch]$NotifyOnError
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)
$launcherState = Join-Path $resolvedState "launcher"
$profilePath = Join-Path $launcherState "workspace-profile.json"
$settingsPath = Join-Path $resolvedState "homepage\config\settings.local.json"
$statusPath = Join-Path $launcherState "workspace-status.json"

if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
  throw "Workspace profile is missing; run configure-workspace.ps1 first."
}
$profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
if ([int]$profile.version -ne 1 -or [string]$profile.repository -ne $repoRoot) {
  throw "Workspace profile belongs to a different repository or unsupported version."
}
$resolvedVault = (Resolve-Path -LiteralPath ([string]$profile.vaultRoot)).Path
if ([string]::IsNullOrWhiteSpace([string]$profile.obsidianVaultName)) {
  throw "Workspace profile has no Obsidian vault name."
}
$websiteConsolePort = if (
  $null -ne $profile.ports.websiteConsole -and
  [int]$profile.ports.websiteConsole -ge 1 -and
  [int]$profile.ports.websiteConsole -le 65535
) { [int]$profile.ports.websiteConsole } else { 8787 }
$resolvedWebsiteRepository = ""
$configuredWebsiteRepository = [string]$profile.website.repository
if (
  -not [string]::IsNullOrWhiteSpace($configuredWebsiteRepository) -and
  (Test-Path -LiteralPath $configuredWebsiteRepository -PathType Container)
) {
  $resolvedWebsiteRepository = (Resolve-Path -LiteralPath $configuredWebsiteRepository).Path
}
$researchAgentPort = if (
  $null -ne $profile.ports.researchAgent -and
  [int]$profile.ports.researchAgent -ge 1024 -and
  [int]$profile.ports.researchAgent -le 65535
) { [int]$profile.ports.researchAgent } else { 8767 }
$resolvedResearchRepository = ""
$resolvedResearchData = ""
$configuredResearchRepository = [string]$profile.research.repository
$configuredResearchData = [string]$profile.research.dataDirectory
if (
  -not [string]::IsNullOrWhiteSpace($configuredResearchRepository) -and
  -not [string]::IsNullOrWhiteSpace($configuredResearchData) -and
  (Test-Path -LiteralPath $configuredResearchRepository -PathType Container)
) {
  $resolvedResearchRepository = (Resolve-Path -LiteralPath $configuredResearchRepository).Path
  $resolvedResearchData = [System.IO.Path]::GetFullPath($configuredResearchData)
}

$settings = if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
  Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
} else {
  [pscustomobject]@{}
}
function Get-StartupBool {
  param([string]$Name, [bool]$Fallback = $true)
  $startup = $settings.startup
  if ($Name.StartsWith("services.")) {
    $property = $Name.Substring("services.".Length)
    if ($startup -and $startup.services -and $null -ne $startup.services.$property) {
      return [bool]$startup.services.$property
    }
    return $Fallback
  }
  if ($startup -and $null -ne $startup.$Name) { return [bool]$startup.$Name }
  return $Fallback
}

$desired = [ordered]@{
  homepage = $true
  calendar = Get-StartupBool "services.calendar"
  email = Get-StartupBool "services.email"
  websiteConsole = Get-StartupBool "services.websiteConsole" $false
  researchAgent = Get-StartupBool "services.researchAgent" $false
  projects = Get-StartupBool "services.projects"
  contacts = Get-StartupBool "services.contacts"
  vaultGraph = Get-StartupBool "services.vaultGraph"
  financeNica = Get-StartupBool "services.financeNica"
  financeTohu = Get-StartupBool "services.financeTohu"
  dictate = Get-StartupBool "services.dictate" $false
}
$dictateModel = if ([string]$settings.dictate.model -in @("multilingual", "german")) { [string]$settings.dictate.model } else { "multilingual" }
$dictateHotkey = if ([string]$settings.dictate.hotkey -in @("ctrl", "ctrl_l", "ctrl_r", "f12")) { [string]$settings.dictate.hotkey } else { "ctrl" }
$dictateMinHoldSeconds = if ($null -ne $settings.dictate.minHoldSeconds) {
  [math]::Max(0, [math]::Min(30, [double]$settings.dictate.minHoldSeconds))
} else { 2.0 }
$open = [ordered]@{
  obsidian = Get-StartupBool "openObsidian"
  homepage = Get-StartupBool "openHomepage"
  calendar = Get-StartupBool "openCalendar"
}
$plan = [ordered]@{
  component = "workspace"
  repository = $repoRoot
  vaultAuthority = $resolvedVault
  localState = $resolvedState
  obsidianVaultName = [string]$profile.obsidianVaultName
  services = $desired
  dictate = [ordered]@{ model = $dictateModel; hotkey = $dictateHotkey; minHoldSeconds = $dictateMinHoldSeconds }
  open = $open
  ports = $profile.ports
}
$plan | ConvertTo-Json -Depth 6
if (-not $Apply) {
  Write-Host "Plan only. Re-run with -Apply to reconcile the configured workspace."
  return
}

New-Item -ItemType Directory -Force -Path $launcherState | Out-Null
$results = [System.Collections.Generic.List[object]]::new()

function Test-ProcessDescendant {
  param(
    [Parameter(Mandatory = $true)][int]$ProcessId,
    [Parameter(Mandatory = $true)][int]$AncestorProcessId
  )
  $currentId = $ProcessId
  for ($depth = 0; $depth -lt 16; $depth += 1) {
    $current = Get-CimInstance Win32_Process -Filter "ProcessId = $currentId" -ErrorAction SilentlyContinue
    if ($null -eq $current) { return $false }
    $parentId = [int]$current.ParentProcessId
    if ($parentId -eq $AncestorProcessId) { return $true }
    if ($parentId -le 0 -or $parentId -eq $currentId) { return $false }
    $currentId = $parentId
  }
  return $false
}

function Test-ManifestProcess {
  param(
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [Parameter(Mandatory = $true)][string[]]$Components,
    [Parameter(Mandatory = $true)][int]$ExpectedPort
  )
  if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return $false }
  try {
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $component = [string]$manifest.component
    $isWebsiteConsole = $component -eq "website-console"
    $isResearchAgent = $component -eq "research-agent"
    $isHomepage = $component -eq "homepage-shell"
    if (
      [string]$manifest.repository -ne $repoRoot -or
      $component -notin $Components -or
      [string]$manifest.stateRoot -ne $resolvedState -or
      [int]$manifest.port -ne $ExpectedPort
    ) { return $false }
    if ($isWebsiteConsole) {
      if (
        [string]::IsNullOrWhiteSpace($resolvedWebsiteRepository) -or
        [string]$manifest.websiteRepository -ne $resolvedWebsiteRepository
      ) { return $false }
    } elseif ($isResearchAgent) {
      if (
        [string]::IsNullOrWhiteSpace($resolvedResearchRepository) -or
        [string]$manifest.researchRepository -ne $resolvedResearchRepository -or
        [string]$manifest.dataDirectory -ne $resolvedResearchData
      ) { return $false }
    } elseif ([string]$manifest.vaultAuthority -ne $resolvedVault) {
      return $false
    }
    if ($isHomepage -and (
      [int]$manifest.dashboardPorts.websiteConsole -ne $websiteConsolePort -or
      [int]$manifest.dashboardPorts.researchAgent -ne $researchAgentPort -or
      [string]$manifest.researchRepository -ne $resolvedResearchRepository -or
      [string]$manifest.researchDataDirectory -ne $resolvedResearchData
    )) { return $false }
    $manifestPid = [int]$manifest.pid
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $manifestPid" -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }

    $isFinance = $component -like "finance-*"
    $favaPattern = '(?i)(?:^|[\\/"\s])fava(?:\.exe)?(?=["\s]|$)'
    $portPattern = '--port(?:=|\s+)' + [regex]::Escape([string]$ExpectedPort) + '(?=["\s]|$)'
    if ($isFinance -and (
      [string]$process.CommandLine -notmatch $favaPattern -or
      [string]$process.CommandLine -notmatch $portPattern
    )) { return $false }
    if ($isWebsiteConsole) {
      $websiteLauncher = (Join-Path $resolvedWebsiteRepository "tools\dev_console.ps1")
      if (
        [string]$process.CommandLine -notmatch ('(?i)(?:^|\s)-Port\s+' + [regex]::Escape([string]$ExpectedPort) + '(?:\s|$)') -or
        ([string]$process.CommandLine).IndexOf($websiteLauncher, [System.StringComparison]::OrdinalIgnoreCase) -lt 0
      ) { return $false }
    }
    if ($isResearchAgent) {
      if (
        [string]$process.CommandLine -notmatch $portPattern -or
        ([string]$process.CommandLine).IndexOf([string]$manifest.launcher, [System.StringComparison]::OrdinalIgnoreCase) -lt 0
      ) { return $false }
    }

    $listeners = @(Get-NetTCPConnection -LocalPort $ExpectedPort -State Listen -ErrorAction SilentlyContinue)
    if ($listeners.Count -eq 0) { return $false }
    if ($manifestPid -in @($listeners | ForEach-Object { [int]$_.OwningProcess })) {
      return $true
    }

    if ($isWebsiteConsole -or $isResearchAgent) {
      $serverPid = [int]$manifest.serverPid
      if ($serverPid -notin @($listeners | ForEach-Object { [int]$_.OwningProcess })) { return $false }
      $serverProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $serverPid" -ErrorAction SilentlyContinue
      return $null -ne $serverProcess -and (Test-ProcessDescendant -ProcessId $serverPid -AncestorProcessId $manifestPid)
    }

    # Windows Python entry-point wrappers retain the manifest PID while their
    # direct python child owns Fava's socket. Accept only that verified shape.
    if ($isFinance) {
      foreach ($listener in $listeners) {
        $owner = Get-CimInstance Win32_Process -Filter "ProcessId = $($listener.OwningProcess)" -ErrorAction SilentlyContinue
        if (
          $null -ne $owner -and
          [int]$owner.ParentProcessId -eq $manifestPid -and
          [string]$owner.CommandLine -match $favaPattern -and
          [string]$owner.CommandLine -match $portPattern
        ) { return $true }
      }
    }
    return $false
  } catch {
    return $false
  }
}

function Test-ResearchAgentHealth {
  param([int]$Port)
  try {
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/ping" -TimeoutSec 2
    return (
      [bool]$health.ok -and
      [string]$health.component -eq "funding-observatory" -and
      [int]$health.api_version -eq 1 -and
      [string]$health.backend -eq "codex"
    )
  } catch {
    return $false
  }
}

function Test-ApiHealth {
  param([int]$Port, [string]$Component, [string]$LocalState)
  try {
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/ping" -TimeoutSec 2
    return (
      [bool]$health.ok -and
      [string]$health.component -eq $Component -and
      [string]$health.authority.vault -eq $resolvedVault -and
      [string]$health.authority.localState -eq $LocalState
    )
  } catch {
    return $false
  }
}

function Test-HttpHealth {
  param([int]$Port)
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/" -TimeoutSec 2
    return [int]$response.StatusCode -eq 200
  } catch {
    return $false
  }
}

function Test-DictateProcess {
  param([string]$ManifestPath)
  if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return $false }
  try {
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if (
      [string]$manifest.repository -ne $repoRoot -or
      [string]$manifest.component -ne "dictate" -or
      [string]$manifest.stateRoot -ne $resolvedState -or
      [string]$manifest.model -ne $dictateModel -or
      [string]$manifest.hotkey -ne $dictateHotkey -or
      [double]$manifest.minHoldSeconds -ne $dictateMinHoldSeconds
    ) { return $false }
    $ready = Get-Content -LiteralPath ([string]$manifest.ready) -Raw | ConvertFrom-Json
    if ([int]$ready.pid -ne [int]$manifest.pid -or [string]$ready.model -ne $dictateModel) { return $false }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$manifest.pid)" -ErrorAction SilentlyContinue
    return $null -ne $process -and [string]$process.CommandLine -like "*Dictate*runner.py*"
  } catch {
    return $false
  }
}

function Test-WebsiteConsoleHealth {
  param([int]$Port)
  try {
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/ping" -TimeoutSec 2
    return (
      [bool]$health.ok -and
      [string]$health.component -eq "nica-website-console" -and
      [int]$health.api_version -eq 1
    )
  } catch {
    return $false
  }
}

function Open-ObsidianWebView {
  param(
    [Parameter(Mandatory = $true)][string]$ApplicationPath,
    [Parameter(Mandatory = $true)][string]$VaultName,
    [Parameter(Mandatory = $true)][string]$Url
  )
  $webOutput = @(& $ApplicationPath web ("vault=" + $VaultName) ("url=" + $Url) newtab 2>&1)
  $webText = $webOutput -join [Environment]::NewLine
  if ($LASTEXITCODE -eq 0 -and $webText -notmatch 'No commands matching') {
    return "web"
  }

  $safeUrl = $Url.Replace("\", "\\").Replace("'", "\'")
  $evalCode = "(async()=>{const leaf=app.workspace.getLeaf('tab');await leaf.setViewState({type:'webviewer',state:{url:'$safeUrl',navigate:true},active:true});return leaf.id})()"
  for ($attempt = 0; $attempt -lt 20; $attempt += 1) {
    $evalOutput = @(& $ApplicationPath eval ("vault=" + $VaultName) ("code=" + $evalCode) 2>&1)
    $evalText = $evalOutput -join [Environment]::NewLine
    if ($LASTEXITCODE -eq 0 -and $evalText -notmatch '(?m)^Error:') {
      return "eval"
    }
    Start-Sleep -Milliseconds 250
  }
  throw "Obsidian could not open $Url in its Web Viewer: $evalText"
}

function Invoke-ReconcileService {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][bool]$Enabled,
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [Parameter(Mandatory = $true)][scriptblock]$IsHealthy,
    [Parameter(Mandatory = $true)][scriptblock]$Start,
    [Parameter(Mandatory = $true)][scriptblock]$Stop
  )
  try {
    if (-not $Enabled) {
      if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {
        & $Stop | Out-Null
        $results.Add([ordered]@{ service = $Name; desired = "stopped"; outcome = "stopped" })
      } else {
        $results.Add([ordered]@{ service = $Name; desired = "stopped"; outcome = "not-running" })
      }
      return
    }
    if (& $IsHealthy) {
      $results.Add([ordered]@{ service = $Name; desired = "running"; outcome = "already-running" })
      return
    }
    if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {
      & $Stop | Out-Null
    }
    & $Start | Out-Null
    if (-not (& $IsHealthy)) { throw "$Name failed its post-start health check." }
    $results.Add([ordered]@{ service = $Name; desired = "running"; outcome = "started" })
  } catch {
    $results.Add([ordered]@{ service = $Name; desired = if ($Enabled) { "running" } else { "stopped" }; outcome = "failed"; error = $_.Exception.Message })
  }
}

if ($open.obsidian) {
  try {
    $vaultUri = "obsidian://open?vault=" + [Uri]::EscapeDataString([string]$profile.obsidianVaultName)
    Start-Process $vaultUri | Out-Null
    $results.Add([ordered]@{ service = "obsidian"; desired = "open"; outcome = "requested" })
  } catch {
    $results.Add([ordered]@{ service = "obsidian"; desired = "open"; outcome = "failed"; error = $_.Exception.Message })
  }
}

$homepageManifest = Join-Path $resolvedState "homepage\homepage-process.json"
Invoke-ReconcileService -Name "homepage" -Enabled $true -ManifestPath $homepageManifest `
  -IsHealthy { (Test-ManifestProcess $homepageManifest @("homepage-shell") ([int]$profile.ports.homepage)) -and (Test-ApiHealth ([int]$profile.ports.homepage) "homepage" (Join-Path $resolvedState "homepage")) } `
  -Start { & (Join-Path $PSScriptRoot "start-homepage.ps1") -VaultRoot $resolvedVault -ObsidianVaultName ([string]$profile.obsidianVaultName) -StateRoot $resolvedState -Port ([int]$profile.ports.homepage) -BeantimeFavaPort ([int]$profile.ports.beantimeFava) -CalendarPort ([int]$profile.ports.calendar) -EmailPort ([int]$profile.ports.email) -WebsiteConsolePort $websiteConsolePort -ResearchAgentPort $researchAgentPort -ResearchRepository $resolvedResearchRepository -ResearchDataDirectory $resolvedResearchData -NicaFavaPort ([int]$profile.ports.financeNica) -TohuFavaPort ([int]$profile.ports.financeTohu) -Apply } `
  -Stop { & (Join-Path $PSScriptRoot "stop-homepage.ps1") -StateRoot $resolvedState }

$dictateManifest = Join-Path $resolvedState "dictate\dictate-process.json"
Invoke-ReconcileService -Name "dictate" -Enabled $desired.dictate -ManifestPath $dictateManifest `
  -IsHealthy { Test-DictateProcess $dictateManifest } `
  -Start { & (Join-Path $PSScriptRoot "start-dictate.ps1") -Model $dictateModel -Hotkey $dictateHotkey -MinHoldSeconds $dictateMinHoldSeconds -StateRoot $resolvedState -Apply } `
  -Stop { & (Join-Path $PSScriptRoot "stop-dictate.ps1") -StateRoot $resolvedState }

$calendarManifest = Join-Path $resolvedState "calendar\calendar-read-process.json"
Invoke-ReconcileService -Name "calendar" -Enabled $desired.calendar -ManifestPath $calendarManifest `
  -IsHealthy { (Test-ManifestProcess $calendarManifest @("calendar-vault-write") ([int]$profile.ports.calendar)) -and (Test-ApiHealth ([int]$profile.ports.calendar) "calendar" (Join-Path $resolvedState "calendar")) } `
  -Start { & (Join-Path $PSScriptRoot "start-calendar-vault-write.ps1") -VaultRoot $resolvedVault -ObsidianVaultName ([string]$profile.obsidianVaultName) -StateRoot $resolvedState -Port ([int]$profile.ports.calendar) -Apply } `
  -Stop { & (Join-Path $PSScriptRoot "stop-calendar-read.ps1") -StateRoot $resolvedState }

$vaultGraphManifest = Join-Path $resolvedState "vaultgraph\cutover-process.json"
Invoke-ReconcileService -Name "vaultgraph" -Enabled $desired.vaultGraph -ManifestPath $vaultGraphManifest `
  -IsHealthy { (Test-ManifestProcess $vaultGraphManifest @("vaultgraph") ([int]$profile.ports.vaultGraph)) -and (Test-ApiHealth ([int]$profile.ports.vaultGraph) "vaultgraph" (Join-Path $resolvedState "vaultgraph")) } `
  -Start { & (Join-Path $PSScriptRoot "start-vaultgraph.ps1") -VaultRoot $resolvedVault -StateRoot $resolvedState -Port ([int]$profile.ports.vaultGraph) -EnableRebuild -Apply } `
  -Stop { & (Join-Path $PSScriptRoot "stop-vaultgraph.ps1") -StateRoot $resolvedState }

$emailManifest = Join-Path $resolvedState "email\email-read-process.json"
Invoke-ReconcileService -Name "email" -Enabled $desired.email -ManifestPath $emailManifest `
  -IsHealthy { (Test-ManifestProcess $emailManifest @("email") ([int]$profile.ports.email)) -and (Test-ApiHealth ([int]$profile.ports.email) "email" (Join-Path $resolvedState "email")) } `
  -Start { & (Join-Path $PSScriptRoot "start-email.ps1") -VaultRoot $resolvedVault -StateRoot $resolvedState -Port ([int]$profile.ports.email) -HomepagePort ([int]$profile.ports.homepage) -Apply } `
  -Stop { & (Join-Path $PSScriptRoot "stop-email.ps1") -StateRoot $resolvedState }

$websiteConsoleManifest = Join-Path $resolvedState "website-console\website-console-process.json"
Invoke-ReconcileService -Name "website-console" -Enabled $desired.websiteConsole -ManifestPath $websiteConsoleManifest `
  -IsHealthy { (Test-ManifestProcess $websiteConsoleManifest @("website-console") $websiteConsolePort) -and (Test-WebsiteConsoleHealth $websiteConsolePort) } `
  -Start {
    if ([string]::IsNullOrWhiteSpace($resolvedWebsiteRepository)) {
      throw "Website console is enabled, but its configured repository is missing or unavailable."
    }
    & (Join-Path $PSScriptRoot "start-website-console.ps1") -WebsiteRepository $resolvedWebsiteRepository -StateRoot $resolvedState -Port $websiteConsolePort -Apply
  } `
  -Stop { & (Join-Path $PSScriptRoot "stop-website-console.ps1") -StateRoot $resolvedState }

$researchAgentManifest = Join-Path $resolvedState "research-agent\research-agent-process.json"
if ($desired.researchAgent) {
  if ((Test-ResearchAgentHealth $researchAgentPort) -and -not (Test-Path -LiteralPath $researchAgentManifest -PathType Leaf)) {
    $results.Add([ordered]@{ service = "research-agent"; desired = "running"; outcome = "external-running" })
  } else {
    Invoke-ReconcileService -Name "research-agent" -Enabled $true -ManifestPath $researchAgentManifest `
      -IsHealthy { (Test-ManifestProcess $researchAgentManifest @("research-agent") $researchAgentPort) -and (Test-ResearchAgentHealth $researchAgentPort) } `
      -Start {
        if ([string]::IsNullOrWhiteSpace($resolvedResearchRepository) -or [string]::IsNullOrWhiteSpace($resolvedResearchData)) {
          throw "Research auto-start is enabled, but its repository or private data directory is not configured."
        }
        & (Join-Path $PSScriptRoot "start-research-agent.ps1") -ResearchRepository $resolvedResearchRepository -DataDirectory $resolvedResearchData -StateRoot $resolvedState -Port $researchAgentPort -Apply
      } `
      -Stop { & (Join-Path $PSScriptRoot "stop-research-agent.ps1") -StateRoot $resolvedState }
  }
} else {
  $results.Add([ordered]@{ service = "research-agent"; desired = "manual"; outcome = "not-reconciled" })
}

foreach ($finance in @(
  [ordered]@{ id = "nica"; name = "finance-nica"; enabled = $desired.financeNica; port = [int]$profile.ports.financeNica; ledger = [string]$profile.finance.nicaLedger },
  [ordered]@{ id = "tohu"; name = "finance-tohu"; enabled = $desired.financeTohu; port = [int]$profile.ports.financeTohu; ledger = [string]$profile.finance.tohuLedger }
)) {
  $manifest = Join-Path $resolvedState "finance\$($finance.id)\finance-process.json"
  $financeCopy = $finance
  Invoke-ReconcileService -Name $financeCopy.name -Enabled $financeCopy.enabled -ManifestPath $manifest `
    -IsHealthy { (Test-ManifestProcess $manifest @("finance-$($financeCopy.id)") $financeCopy.port) -and (Test-HttpHealth $financeCopy.port) } `
    -Start { & (Join-Path $PSScriptRoot "start-finance.ps1") -FinanceId $financeCopy.id -VaultRoot $resolvedVault -LedgerRelativePath $financeCopy.ledger -StateRoot $resolvedState -Port $financeCopy.port -Apply } `
    -Stop { & (Join-Path $PSScriptRoot "stop-finance.ps1") -FinanceId $financeCopy.id -StateRoot $resolvedState }
}

$obsidian = Get-Command obsidian -ErrorAction SilentlyContinue
if ($obsidian) {
  if ($open.homepage -and (Test-ApiHealth ([int]$profile.ports.homepage) "homepage" (Join-Path $resolvedState "homepage"))) {
    try {
      $method = Open-ObsidianWebView -ApplicationPath $obsidian.Source -VaultName ([string]$profile.obsidianVaultName) -Url ("http://127.0.0.1:" + [int]$profile.ports.homepage + "/home.html")
      $results.Add([ordered]@{ service = "homepage-view"; desired = "open"; outcome = "opened"; method = $method })
    } catch {
      $results.Add([ordered]@{ service = "homepage-view"; desired = "open"; outcome = "failed"; error = $_.Exception.Message })
    }
  }
  if ($open.calendar -and $desired.calendar -and (Test-ApiHealth ([int]$profile.ports.calendar) "calendar" (Join-Path $resolvedState "calendar"))) {
    try {
      $method = Open-ObsidianWebView -ApplicationPath $obsidian.Source -VaultName ([string]$profile.obsidianVaultName) -Url ("http://127.0.0.1:" + [int]$profile.ports.calendar + "/cal.html")
      $results.Add([ordered]@{ service = "calendar-view"; desired = "open"; outcome = "opened"; method = $method })
    } catch {
      $results.Add([ordered]@{ service = "calendar-view"; desired = "open"; outcome = "failed"; error = $_.Exception.Message })
    }
  }
} elseif ($open.homepage -or ($open.calendar -and $desired.calendar)) {
  $results.Add([ordered]@{ service = "obsidian-views"; desired = "open"; outcome = "failed"; error = "Obsidian CLI was not found on PATH." })
}

$failed = @($results | Where-Object { $_.outcome -eq "failed" })
$status = [ordered]@{
  version = 1
  ok = $failed.Count -eq 0
  repository = $repoRoot
  appliedAt = (Get-Date).ToString("o")
  results = @($results)
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($statusPath, (($status | ConvertTo-Json -Depth 8) + [Environment]::NewLine), $utf8NoBom)
$status | ConvertTo-Json -Depth 8
if ($failed.Count) {
  if ($NotifyOnError) {
    try { (New-Object -ComObject WScript.Shell).Popup("Workspace started with $($failed.Count) failed service(s). Review $statusPath", 0, "NICA Command Centre", 48) | Out-Null } catch { }
  }
  throw "Workspace reconciliation completed with $($failed.Count) failed service(s)."
}
