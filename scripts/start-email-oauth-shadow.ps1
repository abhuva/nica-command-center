[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$VaultRoot,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [string]$LegacyToolsRoot = "",
  [int]$Port = 4276,
  [int]$HomepagePort = 4274,
  [int]$OAuthCallbackPort = 8080,
  [switch]$InitializeFreshDatabase,
  [switch]$PrepareFetchProfile,
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$parameters = @{
  VaultRoot = $VaultRoot
  StateRoot = $StateRoot
  Port = $Port
  HomepagePort = $HomepagePort
  OAuthCallbackPort = $OAuthCallbackPort
  EnableClassification = $true
  EnableOAuth = $true
}
if (-not [string]::IsNullOrWhiteSpace($LegacyToolsRoot)) {
  $parameters.LegacyToolsRoot = $LegacyToolsRoot
}
if ($InitializeFreshDatabase) { $parameters.InitializeFreshDatabase = $true }
if ($PrepareFetchProfile) { $parameters.PrepareFetchProfile = $true }
if ($Apply) { $parameters.Apply = $true }

& (Join-Path $PSScriptRoot "start-email-fetch-shadow.ps1") @parameters
