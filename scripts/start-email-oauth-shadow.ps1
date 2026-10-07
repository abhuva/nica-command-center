[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$VaultRoot,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [string]$LegacyToolsRoot = "",
  [int]$Port = 4276,
  [int]$OAuthCallbackPort = 8080,
  [switch]$BackupOAuthTokens,
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$parameters = @{
  VaultRoot = $VaultRoot
  StateRoot = $StateRoot
  Port = $Port
  OAuthCallbackPort = $OAuthCallbackPort
  EnableClassification = $true
  EnableOAuth = $true
}
if (-not [string]::IsNullOrWhiteSpace($LegacyToolsRoot)) {
  $parameters.LegacyToolsRoot = $LegacyToolsRoot
}
if ($BackupOAuthTokens) { $parameters.BackupOAuthTokens = $true }
if ($Apply) { $parameters.Apply = $true }

& (Join-Path $PSScriptRoot "start-email-fetch-shadow.ps1") @parameters
