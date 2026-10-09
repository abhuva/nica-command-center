[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live")
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)
$componentState = Join-Path $resolvedState "dictate"
$manifestPath = Join-Path $componentState "dictate-process.json"
$readyPath = Join-Path $componentState "dictate-ready.json"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue
  Write-Host "No Dictate process manifest found."
  return
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ([string]$manifest.repository -ne $repoRoot -or [string]$manifest.component -ne "dictate" -or [string]$manifest.stateRoot -ne $resolvedState) {
  throw "Dictate process manifest belongs to a different repository, state root, or component."
}

$runner = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$manifest.pid)" -ErrorAction SilentlyContinue
if ($runner) {
  $expectedRunner = Join-Path $repoRoot "Dictate\runner.py"
  if ([string]$runner.CommandLine -notlike "*$expectedRunner*") {
    throw "PID $($manifest.pid) does not match the recorded Dictate runner."
  }
  if ($PSCmdlet.ShouldProcess("PID $($manifest.pid) (Dictate)", "Stop Dictate")) {
    $process = Get-Process -Id ([int]$manifest.pid) -ErrorAction SilentlyContinue
    if ($process -and $process.MainWindowHandle -ne 0) { [void]$process.CloseMainWindow() }
    Wait-Process -Id ([int]$manifest.pid) -Timeout 8 -ErrorAction SilentlyContinue
    if (Get-Process -Id ([int]$manifest.pid) -ErrorAction SilentlyContinue) {
      Stop-Process -Id ([int]$manifest.pid) -Force
    }
  }
}
if ($manifest.launcherPid) {
  $launcher = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$manifest.launcherPid)" -ErrorAction SilentlyContinue
  if ($launcher -and [string]$launcher.CommandLine -like "*pythonw.exe*") {
    Stop-Process -Id ([int]$manifest.launcherPid) -Force -ErrorAction SilentlyContinue
  }
}
Remove-Item -LiteralPath $manifestPath, $readyPath -Force -ErrorAction SilentlyContinue
Write-Host "Dictate is stopped; installed models and local configuration were retained."
