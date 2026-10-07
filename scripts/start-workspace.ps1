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
  vaultGraph = Get-StartupBool "services.vaultGraph"
  financeNica = Get-StartupBool "services.financeNica"
  financeTohu = Get-StartupBool "services.financeTohu"
}
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

function Test-ManifestProcess {
  param(
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [Parameter(Mandatory = $true)][string[]]$Components,
    [Parameter(Mandatory = $true)][int]$ExpectedPort
  )
  if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return $false }
  try {
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if (
      [string]$manifest.repository -ne $repoRoot -or
      [string]$manifest.component -notin $Components -or
      [string]$manifest.vaultAuthority -ne $resolvedVault -or
      [string]$manifest.stateRoot -ne $resolvedState -or
      [int]$manifest.port -ne $ExpectedPort
    ) { return $false }
    $manifestPid = [int]$manifest.pid
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $manifestPid" -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }

    $isFinance = [string]$manifest.component -like "finance-*"
    $favaPattern = '(?i)(?:^|[\\/"\s])fava(?:\.exe)?(?=["\s]|$)'
    $portPattern = '--port(?:=|\s+)' + [regex]::Escape([string]$ExpectedPort) + '(?=["\s]|$)'
    if ($isFinance -and (
      [string]$process.CommandLine -notmatch $favaPattern -or
      [string]$process.CommandLine -notmatch $portPattern
    )) { return $false }

    $listeners = @(Get-NetTCPConnection -LocalPort $ExpectedPort -State Listen -ErrorAction SilentlyContinue)
    if ($listeners.Count -eq 0) { return $false }
    if ($manifestPid -in @($listeners | ForEach-Object { [int]$_.OwningProcess })) {
      return $true
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
  -Start { & (Join-Path $PSScriptRoot "start-homepage.ps1") -VaultRoot $resolvedVault -ObsidianVaultName ([string]$profile.obsidianVaultName) -StateRoot $resolvedState -Port ([int]$profile.ports.homepage) -BeantimeFavaPort ([int]$profile.ports.beantimeFava) -Apply } `
  -Stop { & (Join-Path $PSScriptRoot "stop-homepage.ps1") -StateRoot $resolvedState }

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
