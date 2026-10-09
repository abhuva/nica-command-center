[CmdletBinding(SupportsShouldProcess = $true)]
param([string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"))

$ErrorActionPreference = "Stop"
$commandCenterRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)
$manifestPath = Join-Path $resolvedState "website-console\website-console-process.json"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  Write-Host "No website console process manifest found."
  return
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.repository -ne $commandCenterRoot -or $manifest.component -ne "website-console") {
  throw "Website console process manifest belongs to a different repository or component."
}

function Test-DescendantProcess {
  param(
    [Parameter(Mandatory = $true)][int]$ProcessId,
    [Parameter(Mandatory = $true)][int]$AncestorProcessId
  )
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
    throw "Website console process tree is incomplete; no process was stopped."
  }
  $launcherPath = [System.IO.Path]::GetFullPath((Join-Path ([string]$manifest.websiteRepository) "tools\dev_console.ps1"))
  $wrapperCommand = [string]$wrapper.CommandLine
  if (
    $wrapperCommand.IndexOf($launcherPath, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -or
    $wrapperCommand -notmatch ('(?i)(?:^|\s)-Port\s+' + [regex]::Escape([string]$manifest.port) + '(?:\s|$)')
  ) {
    throw "Recorded wrapper PID does not match the website console launcher."
  }
  if (-not (Test-DescendantProcess -ProcessId ([int]$server.ProcessId) -AncestorProcessId ([int]$wrapper.ProcessId))) {
    throw "Recorded website console server is not owned by its launcher."
  }
  $listeners = @(Get-NetTCPConnection -LocalPort ([int]$manifest.port) -State Listen -ErrorAction SilentlyContinue)
  if ($listeners.Count -ne 1 -or [int]$listeners[0].OwningProcess -ne [int]$server.ProcessId) {
    throw "Website console listener does not match the recorded server process."
  }
  try {
    $ping = Invoke-RestMethod -Uri "http://127.0.0.1:$($manifest.port)/api/ping" -TimeoutSec 2
    if ($ping.component -ne "nica-website-console" -or [int]$ping.api_version -ne [int]$manifest.apiVersion) {
      throw "Website console API identity does not match the manifest."
    }
    if ([bool]$ping.busy) {
      throw "Website console is busy with a translation, build, check, or deployment; it was not stopped."
    }
  } catch {
    throw "Website console could not be stopped safely: $($_.Exception.Message)"
  }
  $serverChildren = @(Get-CimInstance Win32_Process | Where-Object { [int]$_.ParentProcessId -eq [int]$server.ProcessId })
  if ($serverChildren.Count) {
    throw "Website console has an active child operation; it was not stopped."
  }

  if ($PSCmdlet.ShouldProcess("PID $($manifest.pid) and server PID $($manifest.serverPid)", "Stop website console")) {
    Stop-Process -Id ([int]$server.ProcessId)
    Wait-Process -Id ([int]$server.ProcessId) -Timeout 5 -ErrorAction SilentlyContinue
    Stop-Process -Id ([int]$wrapper.ProcessId) -ErrorAction SilentlyContinue
    Wait-Process -Id ([int]$wrapper.ProcessId) -Timeout 5 -ErrorAction SilentlyContinue
  }
}
if (Get-NetTCPConnection -LocalPort ([int]$manifest.port) -State Listen -ErrorAction SilentlyContinue) {
  throw "Website console port $($manifest.port) is still occupied; the manifest was retained."
}
Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
Write-Host "Website console is stopped; website files and local credentials were retained."
