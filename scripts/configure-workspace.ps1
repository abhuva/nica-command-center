[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$VaultRoot,
  [Parameter(Mandatory = $true)][string]$ObsidianVaultName,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [int]$HomepagePort = 4274,
  [int]$CalendarPort = 4273,
  [int]$VaultGraphPort = 4175,
  [int]$EmailPort = 4276,
  [string]$WebsiteRepository = "",
  [int]$WebsiteConsolePort = 8787,
  [string]$ResearchRepository = "",
  [string]$ResearchDataDirectory = "",
  [int]$ResearchAgentPort = 8767,
  [int]$BeantimeFavaPort = 3464,
  [int]$NicaFavaPort = 4998,
  [int]$TohuFavaPort = 4999,
  [string]$NicaLedger = "1. Vereinsverwaltung/Buchhaltung/Buchhaltung-NICA/2023/nica.beancount",
  [string]$TohuLedger = "1. Vereinsverwaltung/Buchhaltung/Buchhaltung-Tohuwabohu/2023/2023.beancount",
  [switch]$Replace,
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedVault = (Resolve-Path -LiteralPath $VaultRoot).Path
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)
$resolvedWebsite = $null
if (-not [string]::IsNullOrWhiteSpace($WebsiteRepository)) {
  $resolvedWebsite = (Resolve-Path -LiteralPath $WebsiteRepository).Path
  if (-not (Test-Path -LiteralPath (Join-Path $resolvedWebsite "tools\dev_console.ps1") -PathType Leaf)) {
    throw "WebsiteRepository has no tools/dev_console.ps1 launcher."
  }
}
$resolvedResearch = $null
$resolvedResearchData = $null
if (-not [string]::IsNullOrWhiteSpace($ResearchRepository)) {
  $resolvedResearch = (Resolve-Path -LiteralPath $ResearchRepository).Path
  if (-not (Test-Path -LiteralPath (Join-Path $resolvedResearch "pyproject.toml") -PathType Leaf)) {
    throw "ResearchRepository has no pyproject.toml."
  }
  if (-not (Test-Path -LiteralPath (Join-Path $resolvedResearch ".venv\Scripts\funding-agent.exe") -PathType Leaf)) {
    throw "ResearchRepository has no installed .venv/Scripts/funding-agent.exe launcher."
  }
  $resolvedResearchData = if ([string]::IsNullOrWhiteSpace($ResearchDataDirectory)) {
    [System.IO.Path]::GetFullPath((Join-Path $resolvedResearch "var\live"))
  } else {
    [System.IO.Path]::GetFullPath($ResearchDataDirectory)
  }
} elseif (-not [string]::IsNullOrWhiteSpace($ResearchDataDirectory)) {
  throw "ResearchDataDirectory requires ResearchRepository."
}

function Resolve-VaultFile {
  param(
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [Parameter(Mandatory = $true)][string]$Label
  )
  if ([System.IO.Path]::IsPathRooted($RelativePath)) {
    throw "$Label must be relative to the configured vault root."
  }
  $candidate = [System.IO.Path]::GetFullPath((Join-Path $resolvedVault $RelativePath))
  $vaultPrefix = $resolvedVault.TrimEnd('\') + '\'
  if (-not $candidate.StartsWith($vaultPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "$Label escapes the configured vault root."
  }
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    throw "$Label was not found: $RelativePath"
  }
  return (Resolve-Path -LiteralPath $candidate).Path
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
if ($resolvedResearchData) {
  $researchDataPrefix = $resolvedResearchData.TrimEnd('\') + '\'
  if (
    $resolvedResearchData -eq $resolvedVault -or
    $resolvedResearchData.StartsWith($vaultPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
    $resolvedVault.StartsWith($researchDataPrefix, [System.StringComparison]::OrdinalIgnoreCase)
  ) { throw "ResearchDataDirectory and VaultRoot must be separate directory trees." }
}
if ([string]::IsNullOrWhiteSpace($ObsidianVaultName)) {
  throw "ObsidianVaultName is required."
}
$ports = @($HomepagePort, $CalendarPort, $VaultGraphPort, $EmailPort, $WebsiteConsolePort, $ResearchAgentPort, $BeantimeFavaPort, $NicaFavaPort, $TohuFavaPort)
if ($ports | Where-Object { $_ -lt 1 -or $_ -gt 65535 }) {
  throw "Workspace ports must be between 1 and 65535."
}
if (($ports | Select-Object -Unique).Count -ne $ports.Count) {
  throw "Workspace ports must be unique."
}

$resolvedNicaLedger = Resolve-VaultFile -RelativePath $NicaLedger -Label "NICA ledger"
$resolvedTohuLedger = Resolve-VaultFile -RelativePath $TohuLedger -Label "TOHU ledger"
$launcherState = Join-Path $resolvedState "launcher"
$profilePath = Join-Path $launcherState "workspace-profile.json"
$profile = [ordered]@{
  version = 1
  repository = $repoRoot
  vaultRoot = $resolvedVault
  obsidianVaultName = $ObsidianVaultName.Trim()
  ports = [ordered]@{
    homepage = $HomepagePort
    calendar = $CalendarPort
    vaultGraph = $VaultGraphPort
    email = $EmailPort
    websiteConsole = $WebsiteConsolePort
    researchAgent = $ResearchAgentPort
    beantimeFava = $BeantimeFavaPort
    financeNica = $NicaFavaPort
    financeTohu = $TohuFavaPort
  }
  finance = [ordered]@{
    nicaLedger = $resolvedNicaLedger.Substring($vaultPrefix.Length).Replace('\', '/')
    tohuLedger = $resolvedTohuLedger.Substring($vaultPrefix.Length).Replace('\', '/')
  }
  website = [ordered]@{
    repository = $resolvedWebsite
  }
  research = [ordered]@{
    repository = $resolvedResearch
    dataDirectory = $resolvedResearchData
  }
  configuredAt = (Get-Date).ToString("o")
}

[ordered]@{
  action = if (Test-Path -LiteralPath $profilePath -PathType Leaf) { "replace" } else { "create" }
  profile = $profilePath
  vaultAuthority = $resolvedVault
  stateRoot = $resolvedState
  obsidianVaultName = $profile.obsidianVaultName
  ports = $profile.ports
  website = $profile.website
  research = $profile.research
  financeLedgers = $profile.finance
} | ConvertTo-Json -Depth 5

if (-not $Apply) {
  Write-Host "Plan only. Re-run with -Apply after reviewing the workspace authority and ports."
  return
}
if ((Test-Path -LiteralPath $profilePath -PathType Leaf) -and -not $Replace) {
  throw "Workspace profile already exists; use -Replace after reviewing the new plan."
}

New-Item -ItemType Directory -Force -Path $launcherState | Out-Null
$stagedPath = Join-Path $launcherState ("workspace-profile." + [Guid]::NewGuid().ToString("N") + ".tmp")
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try {
  [System.IO.File]::WriteAllText(
    $stagedPath,
    (($profile | ConvertTo-Json -Depth 10) + [Environment]::NewLine),
    $utf8NoBom
  )
  Get-Content -LiteralPath $stagedPath -Raw | ConvertFrom-Json | Out-Null
  Move-Item -LiteralPath $stagedPath -Destination $profilePath -Force
} finally {
  Remove-Item -LiteralPath $stagedPath -Force -ErrorAction SilentlyContinue
}
Write-Host "Workspace profile configured."
