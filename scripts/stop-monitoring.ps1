[CmdletBinding(SupportsShouldProcess = $true)]
param([string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"))

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)
$componentState = Join-Path $resolvedState "homepage"
$manifestPath = Join-Path $componentState "monitoring-process.json"

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  Write-Host "No monitoring process manifest found."
  exit 0
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.repository -ne $repoRoot -or $manifest.component -ne "monitoring") {
  throw "Monitoring process manifest belongs to a different repository or component."
}

$proc = Get-CimInstance Win32_Process -Filter "ProcessId = $($manifest.pid)" -ErrorAction SilentlyContinue
if ($proc) {
  $expectedServer = (Join-Path $repoRoot "serve.mjs").ToLowerInvariant()
  $commandLine = [string]$proc.CommandLine
  if ($commandLine.ToLowerInvariant().IndexOf($expectedServer, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw "PID $($manifest.pid) does not match this repository's Homepage server."
  }

  $children = @(Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $manifest.pid })
  $unexpectedChildren = @($children | Where-Object { $_.Name -notin @("updo.exe", "updo", "conhost.exe") })
  if ($unexpectedChildren.Count) {
    throw "Monitoring server has an unexpected child process; no process was stopped."
  }
  $monitorChildren = @($children | Where-Object { $_.Name -in @("updo.exe", "updo") })

  if ($PSCmdlet.ShouldProcess("PID $($manifest.pid) (monitoring)", "Stop cutover process")) {
    Stop-Process -Id $manifest.pid
    Wait-Process -Id $manifest.pid -Timeout 5 -ErrorAction SilentlyContinue
    foreach ($child in $monitorChildren) {
      Stop-Process -Id $child.ProcessId -ErrorAction SilentlyContinue
      Wait-Process -Id $child.ProcessId -Timeout 5 -ErrorAction SilentlyContinue
    }
  }
}

$listener = Get-NetTCPConnection -LocalPort ([int]$manifest.port) -State Listen -ErrorAction SilentlyContinue
if ($listener) {
  throw "Monitoring port $($manifest.port) is still occupied; the manifest was retained."
}

Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
Write-Host "Monitoring cutover process is stopped; configuration and history were retained."
