[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidateSet("multilingual", "german")][string]$Model,
  [ValidateSet("ctrl", "ctrl_l", "ctrl_r", "f12")][string]$Hotkey = "ctrl",
  [ValidateRange(0, 30)][double]$MinHoldSeconds = 2.0,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)
$manifestPath = Join-Path $resolvedState "dictate\dictate-process.json"
$previous = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
  Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
} else { $null }
$plan = [ordered]@{
  component = "dictate-model-switch"
  from = if ($previous) { [string]$previous.model } else { $null }
  to = $Model
  stateRoot = $resolvedState
  rollbackModel = if ($previous) { [string]$previous.model } else { $null }
}
$plan | ConvertTo-Json -Depth 4

# Validate the target before stopping a healthy current process.
& (Join-Path $PSScriptRoot "start-dictate.ps1") -Model $Model -Hotkey $Hotkey -MinHoldSeconds $MinHoldSeconds -StateRoot $resolvedState | Out-Null
if (-not $Apply) {
  Write-Host "Plan only. Re-run with -Apply to stop Dictate and load the selected model."
  return
}

if ($previous) {
  & (Join-Path $PSScriptRoot "stop-dictate.ps1") -StateRoot $resolvedState
}
try {
  & (Join-Path $PSScriptRoot "start-dictate.ps1") -Model $Model -Hotkey $Hotkey -MinHoldSeconds $MinHoldSeconds -StateRoot $resolvedState -Apply
} catch {
  $switchError = $_
  if ($previous -and [string]$previous.model -ne $Model) {
    try {
      & (Join-Path $PSScriptRoot "start-dictate.ps1") -Model ([string]$previous.model) -Hotkey ([string]$previous.hotkey) -MinHoldSeconds ([double]$previous.minHoldSeconds) -StateRoot $resolvedState -Apply | Out-Null
    } catch {
      throw "Dictate failed to load '$Model', and rollback to '$($previous.model)' also failed: $($_.Exception.Message). Original switch error: $($switchError.Exception.Message)"
    }
  }
  throw $switchError
}
