[CmdletBinding(SupportsShouldProcess = $true)]
param([string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"))

$ErrorActionPreference = "Stop"
$commandCenterRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)
$manifestPath = Join-Path $resolvedState "research-agent\research-agent-process.json"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  Write-Host "No managed research agent process manifest found."
  return
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if (
  [string]$manifest.repository -ne $commandCenterRoot -or
  [string]$manifest.component -ne "research-agent" -or
  [string]$manifest.stateRoot -ne $resolvedState
) { throw "Research process manifest belongs to a different repository, state root, or component." }

function Test-DescendantProcess {
  param([int]$ProcessId, [int]$AncestorProcessId)
  $currentId = $ProcessId
  for ($depth = 0; $depth -lt 16; $depth += 1) {
    $current = Get-CimInstance Win32_Process -Filter "ProcessId = $currentId" -ErrorAction SilentlyContinue
    if ($null -eq $current) { return $false }
    $parentId = [int]$current.ParentProcessId
    if ($parentId -eq $AncestorProcessId) { return $true }
    if ($parentId -le 0 -or $parentId -eq $currentId) { return $false }
    $currentId = $parentId
  }
  return $false
}

$wrapper = Get-CimInstance Win32_Process -Filter "ProcessId = $($manifest.pid)" -ErrorAction SilentlyContinue
$server = Get-CimInstance Win32_Process -Filter "ProcessId = $($manifest.serverPid)" -ErrorAction SilentlyContinue
if ($wrapper -or $server) {
  if ($null -eq $wrapper -or $null -eq $server) {
    throw "Research process tree is incomplete; no process was stopped."
  }
  $wrapperCommand = [string]$wrapper.CommandLine
  if (
    $wrapperCommand.IndexOf([string]$manifest.launcher, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -or
    $wrapperCommand -notmatch ('--port(?:=|\s+)' + [regex]::Escape([string]$manifest.port) + '(?:\s|$)') -or
    $wrapperCommand.IndexOf([string]$manifest.dataDirectory, [System.StringComparison]::OrdinalIgnoreCase) -lt 0
  ) { throw "Recorded launcher PID does not match the research command." }
  if (
    [int]$server.ProcessId -ne [int]$wrapper.ProcessId -and
    -not (Test-DescendantProcess -ProcessId ([int]$server.ProcessId) -AncestorProcessId ([int]$wrapper.ProcessId))
  ) { throw "Recorded research server is not owned by its launcher." }
  $listeners = @(Get-NetTCPConnection -LocalPort ([int]$manifest.port) -State Listen -ErrorAction SilentlyContinue)
  if ($listeners.Count -ne 1 -or [int]$listeners[0].OwningProcess -ne [int]$server.ProcessId) {
    throw "Research listener does not match the recorded process."
  }
  try {
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:$($manifest.port)/api/ping" -TimeoutSec 2
    if (
      -not [bool]$health.ok -or
      [string]$health.component -ne "funding-observatory" -or
      [int]$health.api_version -ne [int]$manifest.apiVersion -or
      [string]$health.backend -ne "codex"
    ) { throw "Research API identity does not match the manifest." }
    if ([bool]$health.busy) {
      throw "Research is active; pause new work and wait for or cancel the current run before stopping."
    }
  } catch {
    throw "Research agent could not be stopped safely: $($_.Exception.Message)"
  }

  if ($PSCmdlet.ShouldProcess("research agent PID $($manifest.serverPid)", "Stop idle managed service")) {
    Stop-Process -Id ([int]$server.ProcessId)
    Wait-Process -Id ([int]$server.ProcessId) -Timeout 8 -ErrorAction SilentlyContinue
    if ([int]$wrapper.ProcessId -ne [int]$server.ProcessId) {
      Stop-Process -Id ([int]$wrapper.ProcessId) -ErrorAction SilentlyContinue
      Wait-Process -Id ([int]$wrapper.ProcessId) -Timeout 5 -ErrorAction SilentlyContinue
    }
  }
}
if (Get-NetTCPConnection -LocalPort ([int]$manifest.port) -State Listen -ErrorAction SilentlyContinue) {
  throw "Research port $($manifest.port) is still occupied; the manifest was retained."
}
Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
Write-Host "Managed research agent is stopped; its private database and profiles were retained."
