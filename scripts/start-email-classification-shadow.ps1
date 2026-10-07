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
  [switch]$BackupCandidate,
  [switch]$RefreshCandidateBackup,
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$parameters = @{
  VaultRoot = $VaultRoot
  StateRoot = $StateRoot
  Port = $Port
  HomepagePort = $HomepagePort
  EnableClassification = $true
}
if (-not [string]::IsNullOrWhiteSpace($LegacyToolsRoot)) {
  $parameters.LegacyToolsRoot = $LegacyToolsRoot
}
if ($RefreshSnapshot) { $parameters.RefreshSnapshot = $true }
if ($InitializeFreshDatabase) { $parameters.InitializeFreshDatabase = $true }
if ($PrepareFetchProfile) { $parameters.PrepareFetchProfile = $true }
if ($BackupCandidate) { $parameters.BackupCandidate = $true }
if ($RefreshCandidateBackup) { $parameters.RefreshCandidateBackup = $true }
if ($Apply) { $parameters.Apply = $true }

& (Join-Path $PSScriptRoot "start-email-fetch-shadow.ps1") @parameters
