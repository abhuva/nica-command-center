$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("nica-workspace-launcher-" + [Guid]::NewGuid().ToString("N"))
$vault = Join-Path $sandbox "vault"
$state = Join-Path $sandbox "state"
$nicaRelative = "finance/nica.beancount"
$tohuRelative = "finance/tohu.beancount"

function Get-FreePort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  try { return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port } finally { $listener.Stop() }
}

try {
  New-Item -ItemType Directory -Force -Path (Join-Path $vault "finance") | Out-Null
  $ledger = @'
option "title" "Synthetic finance"
option "operating_currency" "EUR"
2031-01-01 open Assets:Cash EUR
'@
  Set-Content -LiteralPath (Join-Path $vault $nicaRelative) -Value $ledger -Encoding utf8
  Set-Content -LiteralPath (Join-Path $vault $tohuRelative) -Value $ledger -Encoding utf8
  $ports = 1..7 | ForEach-Object { Get-FreePort }
  $configure = Join-Path $repoRoot "scripts\configure-workspace.ps1"
  $arguments = @{
    VaultRoot = $vault
    ObsidianVaultName = "Synthetic Workspace"
    StateRoot = $state
    HomepagePort = $ports[0]
    CalendarPort = $ports[1]
    VaultGraphPort = $ports[2]
    EmailPort = $ports[3]
    BeantimeFavaPort = $ports[4]
    NicaFavaPort = $ports[5]
    TohuFavaPort = $ports[6]
    NicaLedger = $nicaRelative
    TohuLedger = $tohuRelative
  }
  & $configure @arguments | Out-Null
  if (Test-Path -LiteralPath (Join-Path $state "launcher\workspace-profile.json")) {
    throw "Plan-only workspace configuration wrote a profile."
  }
  & $configure @arguments -Apply | Out-Null
  $profilePath = Join-Path $state "launcher\workspace-profile.json"
  $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
  if ($profile.obsidianVaultName -ne "Synthetic Workspace" -or $profile.finance.nicaLedger -ne $nicaRelative) {
    throw "Workspace profile did not preserve the synthetic configuration."
  }
  & (Join-Path $repoRoot "scripts\stop-workspace.ps1") -StateRoot $state | Out-Null

  $settingsPath = Join-Path $state "homepage\config\settings.local.json"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $settingsPath) | Out-Null
  [ordered]@{
    schemaVersion = 3
    startup = [ordered]@{
      openObsidian = $false
      openHomepage = $false
      openCalendar = $false
      services = [ordered]@{
        calendar = $false
        email = $true
        vaultGraph = $false
        financeNica = $true
        financeTohu = $false
        dictate = $false
      }
    }
    dictate = [ordered]@{ model = "multilingual"; hotkey = "ctrl"; minHoldSeconds = 2.0 }
  } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $settingsPath -Encoding utf8
  $planText = (& (Join-Path $repoRoot "scripts\start-workspace.ps1") -StateRoot $state | Out-String)
  if ($planText -notmatch '"email"\s*:\s*true' -or $planText -notmatch '"calendar"\s*:\s*false') {
    throw "Workspace plan did not honor local startup service choices."
  }

  $financePort = Get-FreePort
  $startFinance = Join-Path $repoRoot "scripts\start-finance.ps1"
  $stopFinance = Join-Path $repoRoot "scripts\stop-finance.ps1"
  & $startFinance -FinanceId nica -VaultRoot $vault -LedgerRelativePath $nicaRelative -StateRoot $state -Port $financePort | Out-Null
  if (Test-Path -LiteralPath (Join-Path $state "finance\nica\finance-process.json")) {
    throw "Plan-only finance startup wrote a process manifest."
  }
  & $startFinance -FinanceId nica -VaultRoot $vault -LedgerRelativePath $nicaRelative -StateRoot $state -Port $financePort -Apply | Out-Null
  $financeManifestPath = Join-Path $state "finance\nica\finance-process.json"
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$financePort/" -TimeoutSec 3
    if ([int]$response.StatusCode -ne 200) { throw "Synthetic finance service was not healthy." }
    $launcherPath = Join-Path $repoRoot "scripts\start-workspace.ps1"
    $parseErrors = $null
    $launcherAst = [System.Management.Automation.Language.Parser]::ParseFile(
      $launcherPath,
      [ref]$null,
      [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) { throw "Workspace launcher could not be parsed for process validation." }
    $manifestFunction = $launcherAst.Find({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Test-ManifestProcess"
    }, $true)
    if ($null -eq $manifestFunction) { throw "Workspace manifest validator was not found." }
    Invoke-Expression $manifestFunction.Extent.Text
    $resolvedVault = (Resolve-Path -LiteralPath $vault).Path
    $resolvedState = [System.IO.Path]::GetFullPath($state)
    if (-not (Test-ManifestProcess $financeManifestPath @("finance-nica") $financePort)) {
      throw "Workspace launcher rejected its synthetic Fava process and listener."
    }
    $financeManifest = Get-Content -LiteralPath $financeManifestPath -Raw | ConvertFrom-Json
    $originalFinancePid = [int]$financeManifest.pid
    try {
      $financeManifest.pid = $PID
      $financeManifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $financeManifestPath -Encoding utf8
      if (Test-ManifestProcess $financeManifestPath @("finance-nica") $financePort) {
        throw "Workspace launcher accepted a non-Fava manifest PID."
      }
    } finally {
      $financeManifest.pid = $originalFinancePid
      $financeManifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $financeManifestPath -Encoding utf8
    }
  } finally {
    & $stopFinance -FinanceId nica -StateRoot $state | Out-Null
  }
  if (Get-NetTCPConnection -LocalPort $financePort -State Listen -ErrorAction SilentlyContinue) {
    throw "Synthetic finance service remained on its port after stop."
  }

  $legacyLedgerRelative = "Tools/data/beantime/zeit.beancount"
  $legacyLedger = Join-Path $vault $legacyLedgerRelative
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $legacyLedger) | Out-Null
  Set-Content -LiteralPath $legacyLedger -Value $ledger -Encoding utf8
  $runtimeProfilePath = Join-Path $state "homepage\config\runtime-profile.json"
  [ordered]@{
    version = 1
    profile = "homepage-project-beantime"
    beantimeLedgerPath = $legacyLedgerRelative
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $runtimeProfilePath -Encoding utf8
  $settingsJson = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
  $settingsJson | Add-Member -NotePropertyName modules -NotePropertyValue ([pscustomobject]@{
    beantime = [pscustomobject]@{ file = "beantime/zeit.beancount"; stateFile = "beantime/state.json" }
  }) -Force
  $settingsJson | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $settingsPath -Encoding utf8
  $migrate = Join-Path $repoRoot "scripts\migrate-beantime-ledger.ps1"
  $destinationRelative = "1. Vereinsverwaltung/Buchhaltung/Zeiterfassung/zeit.beancount"
  & $migrate -VaultRoot $vault -StateRoot $state -DestinationRelativePath $destinationRelative | Out-Null
  if (Test-Path -LiteralPath (Join-Path $vault $destinationRelative)) {
    throw "Plan-only Beantime migration wrote the destination ledger."
  }
  $timerState = Join-Path $state "homepage\beantime\state.json"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $timerState) | Out-Null
  @{ startedAt = "2031-01-01T10:00:00Z"; account = "Projekte:Synthetic" } | ConvertTo-Json | Set-Content -LiteralPath $timerState -Encoding utf8
  $blocked = $false
  try {
    & $migrate -VaultRoot $vault -StateRoot $state -DestinationRelativePath $destinationRelative -Apply | Out-Null
  } catch {
    $blocked = $_.Exception.Message -match "active Beantime timer"
  }
  if (-not $blocked) { throw "Beantime migration did not reject an active timer." }
  Remove-Item -LiteralPath $timerState -Force
  & $migrate -VaultRoot $vault -StateRoot $state -DestinationRelativePath $destinationRelative -Apply | Out-Null
  $destinationLedger = Join-Path $vault $destinationRelative
  if (-not (Test-Path -LiteralPath $legacyLedger -PathType Leaf) -or -not (Test-Path -LiteralPath $destinationLedger -PathType Leaf)) {
    throw "Beantime migration did not retain the source and publish the destination."
  }
  if ((Get-FileHash $legacyLedger).Hash -ne (Get-FileHash $destinationLedger).Hash) {
    throw "Beantime migration changed the copied ledger content."
  }
  $migratedProfile = Get-Content -LiteralPath $runtimeProfilePath -Raw | ConvertFrom-Json
  if ($migratedProfile.beantimeLedgerPath -ne $destinationRelative) {
    throw "Beantime migration did not switch the runtime profile."
  }
  $restore = Join-Path $repoRoot "scripts\restore-beantime-ledger-profile.ps1"
  & $restore -VaultRoot $vault -StateRoot $state | Out-Null
  $stillMigrated = Get-Content -LiteralPath $runtimeProfilePath -Raw | ConvertFrom-Json
  if ($stillMigrated.beantimeLedgerPath -ne $destinationRelative) {
    throw "Plan-only Beantime rollback changed the runtime profile."
  }
  Add-Content -LiteralPath $destinationLedger -Value "; synthetic post-cutover booking"
  & $restore -VaultRoot $vault -StateRoot $state -Apply | Out-Null
  $restoredProfile = Get-Content -LiteralPath $runtimeProfilePath -Raw | ConvertFrom-Json
  if ($restoredProfile.beantimeLedgerPath -ne $legacyLedgerRelative) {
    throw "Beantime rollback did not restore the source profile."
  }
  if ((Get-FileHash $legacyLedger).Hash -ne (Get-FileHash $destinationLedger).Hash) {
    throw "Beantime rollback did not preserve destination changes in the restored source."
  }
  $recoveryCopies = @(Get-ChildItem -LiteralPath (Join-Path $state "launcher\recovery") -Filter "beantime-source-pre-rollback-*.beancount")
  if ($recoveryCopies.Count -ne 1) {
    throw "Beantime rollback did not retain exactly one verified local recovery copy."
  }
  & $migrate -VaultRoot $vault -StateRoot $state -DestinationRelativePath $destinationRelative -Apply | Out-Null
  $reactivatedProfile = Get-Content -LiteralPath $runtimeProfilePath -Raw | ConvertFrom-Json
  if ($reactivatedProfile.beantimeLedgerPath -ne $destinationRelative) {
    throw "Beantime migration did not reactivate the matching destination copy."
  }
  Write-Output "Workspace launcher smoke check OK"
} finally {
  if (Test-Path -LiteralPath $sandbox) {
    $resolvedSandbox = [System.IO.Path]::GetFullPath($sandbox)
    $tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedSandbox.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Synthetic workspace sandbox escaped the temporary directory."
    }
    Remove-Item -LiteralPath $resolvedSandbox -Recurse -Force
  }
}
