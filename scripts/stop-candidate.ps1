[CmdletBinding(SupportsShouldProcess = $true)]
param([string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\candidate"))

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$manifestPath = Join-Path ([System.IO.Path]::GetFullPath($StateRoot)) "launcher\processes.json"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  Write-Host "No candidate process manifest found."
  exit 0
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.repository -ne $repoRoot) { throw "Candidate manifest belongs to a different repository." }
foreach ($entry in $manifest.processes) {
  $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $($entry.pid)" -ErrorAction SilentlyContinue
  if (-not $proc) { continue }
  if ([string]$proc.CommandLine -notlike "*$repoRoot*") {
    Write-Warning "Skipped PID $($entry.pid): command line does not reference this repository."
    continue
  }
  if ($PSCmdlet.ShouldProcess("PID $($entry.pid) ($($entry.name))", "Stop candidate process")) {
    Stop-Process -Id $entry.pid
  }
}
