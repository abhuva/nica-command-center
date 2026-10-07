[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$VaultRoot,
  [Parameter(Mandatory = $true)][string]$ObsidianVaultName,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [string]$LegacyToolsRoot = "",
  [int]$Port = 4273,
  [switch]$InitializeReadProfile,
  [switch]$AllowMarkdownFallback,
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$launcher = Join-Path $PSScriptRoot "start-calendar-read.ps1"
$arguments = @{
  VaultRoot = $VaultRoot
  ObsidianVaultName = $ObsidianVaultName
  StateRoot = $StateRoot
  LegacyToolsRoot = $LegacyToolsRoot
  Port = $Port
  EnableVaultEventCreate = $true
}
if ($InitializeReadProfile) { $arguments.InitializeReadProfile = $true }
if ($AllowMarkdownFallback) { $arguments.AllowMarkdownFallback = $true }
if ($Apply) { $arguments.Apply = $true }

& $launcher @arguments
