[CmdletBinding()]
param(
  [ValidateSet("multilingual", "german")][string]$Model = "multilingual",
  [ValidateSet("ctrl", "ctrl_l", "ctrl_r", "f12")][string]$Hotkey = "ctrl",
  [ValidateRange(0, 30)][double]$MinHoldSeconds = 2.0,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)
$componentState = Join-Path $resolvedState "dictate"
$modelDir = Join-Path $componentState ("models\" + $Model)
$manifestPath = Join-Path $componentState "dictate-process.json"
$readyPath = Join-Path $componentState "dictate-ready.json"
$registry = Get-Content -LiteralPath (Join-Path $repoRoot "Dictate\model-registry.json") -Raw | ConvertFrom-Json
$modelEntry = @($registry.models | Where-Object { [string]$_.id -eq $Model })
if ($modelEntry.Count -ne 1) { throw "Dictate model '$Model' is not registered." }
foreach ($file in $modelEntry[0].files) {
  $path = Join-Path $modelDir ([string]$file.name)
  if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -ne [long]$file.bytes) {
    throw "Dictate model '$Model' is not installed completely; run setup-dictate.ps1 first."
  }
}
$pythonw = Join-Path $componentState "runtime\.venv\Scripts\pythonw.exe"
if (-not (Test-Path -LiteralPath $pythonw -PathType Leaf)) {
  throw "Dictate runtime is not installed; run setup-dictate.ps1 first."
}

$plan = [ordered]@{
  component = "dictate"
  repository = $repoRoot
  localState = $componentState
  model = $Model
  modelDirectory = $modelDir
  hotkey = $Hotkey
  minHoldSeconds = $MinHoldSeconds
  audioRetention = $false
  cloudTranscription = $false
}
$plan | ConvertTo-Json -Depth 5
if (-not $Apply) {
  Write-Host "Plan only. Re-run with -Apply to start local dictation."
  return
}
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
  throw "Dictate process manifest already exists; use stop-dictate.ps1 first."
}

New-Item -ItemType Directory -Force -Path (Join-Path $componentState "logs") | Out-Null
Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue
$stdout = Join-Path $componentState "logs\dictate.out.log"
$stderr = Join-Path $componentState "logs\dictate.err.log"
$runner = Join-Path $repoRoot "Dictate\runner.py"
function Quote-ProcessArgument([string]$Value) {
  return '"' + $Value.Replace('"', '\"') + '"'
}
$arguments = @(
  Quote-ProcessArgument $runner
  "--state-root", (Quote-ProcessArgument $componentState)
  "--model-dir", (Quote-ProcessArgument $modelDir)
  "--model", $Model
  "--hotkey", $Hotkey
  "--min-hold", ([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:0.0}", $MinHoldSeconds))
  "--ready-file", (Quote-ProcessArgument $readyPath)
) -join " "

$launcher = $null
try {
  $launcher = Start-Process -FilePath $pythonw -ArgumentList $arguments -WorkingDirectory (Join-Path $repoRoot "Dictate") -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
  $ready = $null
  for ($attempt = 0; $attempt -lt 180; $attempt += 1) {
    $launcher.Refresh()
    if ($launcher.HasExited) { throw "Dictate exited before it became ready; review $stderr" }
    if (Test-Path -LiteralPath $readyPath -PathType Leaf) {
      try {
        $candidate = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
        if ([string]$candidate.model -eq $Model -and [string]$candidate.hotkey -eq $Hotkey) {
          $ready = $candidate
          break
        }
      } catch { }
    }
    Start-Sleep -Milliseconds 500
  }
  if ($null -eq $ready) { throw "Dictate did not become ready within 90 seconds; review $stderr" }
  $runnerProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$ready.pid)" -ErrorAction SilentlyContinue
  if ($null -eq $runnerProcess -or [string]$runnerProcess.CommandLine -notlike "*$runner*") {
    throw "Dictate readiness record does not identify the expected runner."
  }
  $manifest = [ordered]@{
    version = 1
    component = "dictate"
    repository = $repoRoot
    stateRoot = $resolvedState
    model = $Model
    hotkey = $Hotkey
    minHoldSeconds = $MinHoldSeconds
    launcherPid = $launcher.Id
    pid = [int]$ready.pid
    startedAt = (Get-Date).ToString("o")
    ready = $readyPath
    stdout = $stdout
    stderr = $stderr
  }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($manifestPath, (($manifest | ConvertTo-Json -Depth 6) + [Environment]::NewLine), $utf8NoBom)
  $manifest | ConvertTo-Json -Depth 6
} catch {
  if (Test-Path -LiteralPath $readyPath -PathType Leaf) {
    try {
      $failedReady = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
      $failedRunner = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$failedReady.pid)" -ErrorAction SilentlyContinue
      if ($failedRunner -and [string]$failedRunner.CommandLine -like "*$runner*") {
        Stop-Process -Id ([int]$failedReady.pid) -Force -ErrorAction SilentlyContinue
      }
    } catch { }
  }
  if ($launcher) { Stop-Process -Id $launcher.Id -Force -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $manifestPath, $readyPath -Force -ErrorAction SilentlyContinue
  throw
}
