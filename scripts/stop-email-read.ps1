[CmdletBinding(SupportsShouldProcess = $true)]
param([string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"))

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)
$componentState = Join-Path $resolvedState "email"
$manifestPath = Join-Path $componentState "email-read-process.json"
$pidPath = Join-Path $componentState "email.preview.pid"

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  Write-Host "No Email read-shadow process manifest found."
  exit 0
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.repository -ne $repoRoot -or $manifest.component -notin @("email", "email-read-shadow", "email-fetch-shadow", "email-classification-shadow", "email-oauth-shadow", "email-export-shadow")) {
  throw "Email process manifest belongs to a different repository or component."
}

$proc = Get-CimInstance Win32_Process -Filter "ProcessId = $($manifest.pid)" -ErrorAction SilentlyContinue
if ($proc) {
  $expectedServer = (Join-Path $repoRoot "Email\email_tool.py").ToLowerInvariant()
  $commandLine = [string]$proc.CommandLine
  if ($commandLine.ToLowerInvariant().IndexOf($expectedServer, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw "PID $($manifest.pid) does not match this repository's Email server."
  }
  if ($PSCmdlet.ShouldProcess("PID $($manifest.pid) ($($manifest.component))", "Stop process")) {
    Stop-Process -Id $manifest.pid
    Wait-Process -Id $manifest.pid -Timeout 5 -ErrorAction SilentlyContinue
  }
}

$listener = Get-NetTCPConnection -LocalPort ([int]$manifest.port) -State Listen -ErrorAction SilentlyContinue
if ($listener) {
  throw "Email port $($manifest.port) is still occupied; the manifest was retained."
}

Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
Write-Host "$($manifest.component) is stopped; its local database, profile, and logs were retained."
