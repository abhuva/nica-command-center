[CmdletBinding(SupportsShouldProcess = $true)]
param([string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"))

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)
$componentState = Join-Path $resolvedState "vaultgraph"
$manifestPath = Join-Path $componentState "cutover-process.json"
$pidPath = Join-Path $componentState "vault-graph.preview.pid"

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  Write-Host "No VaultGraph cutover process manifest found."
  exit 0
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.repository -ne $repoRoot -or $manifest.component -ne "vaultgraph") {
  throw "VaultGraph process manifest belongs to a different repository or component."
}

$proc = Get-CimInstance Win32_Process -Filter "ProcessId = $($manifest.pid)" -ErrorAction SilentlyContinue
if ($proc) {
  $expectedServer = (Join-Path $repoRoot "VaultGraph\serve.mjs").ToLowerInvariant()
  $commandLine = [string]$proc.CommandLine
  if ($commandLine.ToLowerInvariant().IndexOf($expectedServer, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw "PID $($manifest.pid) does not match this repository's VaultGraph server."
  }
  if ($PSCmdlet.ShouldProcess("PID $($manifest.pid) (VaultGraph)", "Stop cutover process")) {
    Stop-Process -Id $manifest.pid
    Wait-Process -Id $manifest.pid -Timeout 5 -ErrorAction SilentlyContinue
  }
}

Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
Write-Host "VaultGraph cutover process is stopped."
