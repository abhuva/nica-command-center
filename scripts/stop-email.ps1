[CmdletBinding()]
param([string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"))

$ErrorActionPreference = "Stop"
& (Join-Path $PSScriptRoot "stop-email-read.ps1") -StateRoot $StateRoot
