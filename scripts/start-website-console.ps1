[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$WebsiteRepository,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [int]$Port = 8787,
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$commandCenterRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedWebsite = (Resolve-Path -LiteralPath $WebsiteRepository).Path
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)
$launcherPath = Join-Path $resolvedWebsite "tools\dev_console.ps1"
if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
  throw "The configured website repository has no tools/dev_console.ps1 launcher."
}
if ($Port -lt 1 -or $Port -gt 65535) { throw "Port must be between 1 and 65535." }

$componentState = Join-Path $resolvedState "website-console"
$manifestPath = Join-Path $componentState "website-console-process.json"
$plan = [ordered]@{
  component = "website-console"
  commandCenterRepository = $commandCenterRoot
  websiteRepository = $resolvedWebsite
  localState = $componentState
  host = "127.0.0.1"
  port = $Port
  remoteWrites = "controlled-by-website-console"
}
$plan | ConvertTo-Json -Depth 4
if (-not $Apply) {
  Write-Host "Plan only. Re-run with -Apply after reviewing the website repository and port."
  return
}
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
  throw "Website console process manifest already exists; use stop-website-console.ps1 first."
}
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
  throw "Website console port $Port is already in use; no process was stopped."
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

function Stop-ProcessTreeBestEffort {
  param([Parameter(Mandatory = $true)][int]$RootProcessId)
  $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
  $ids = [System.Collections.Generic.List[int]]::new()
  $frontier = @($RootProcessId)
  while ($frontier.Count) {
    $next = @()
    foreach ($parentId in $frontier) {
      foreach ($child in @($all | Where-Object { [int]$_.ParentProcessId -eq $parentId })) {
        $ids.Add([int]$child.ProcessId)
        $next += [int]$child.ProcessId
      }
    }
    $frontier = $next
  }
  for ($index = $ids.Count - 1; $index -ge 0; $index -= 1) {
    Stop-Process -Id $ids[$index] -Force -ErrorAction SilentlyContinue
  }
  Stop-Process -Id $RootProcessId -Force -ErrorAction SilentlyContinue
}

$powershell = Get-Command powershell -ErrorAction Stop
New-Item -ItemType Directory -Force -Path $componentState | Out-Null
$stdout = Join-Path $componentState "website-console.out.log"
$stderr = Join-Path $componentState "website-console.err.log"
$arguments = @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", ('"' + $launcherPath + '"'),
  "-HostAddress", "127.0.0.1",
  "-Port", [string]$Port
) -join " "
$proc = $null
try {
  $proc = Start-Process -FilePath $powershell.Source -ArgumentList $arguments -WorkingDirectory $resolvedWebsite -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
  $manifest = [ordered]@{
    component = "website-console"
    repository = $commandCenterRoot
    websiteRepository = $resolvedWebsite
    stateRoot = $resolvedState
    host = "127.0.0.1"
    port = $Port
    pid = $proc.Id
    serverPid = $null
    apiVersion = 1
    startedAt = (Get-Date).ToString("o")
    stdout = $stdout
    stderr = $stderr
  }
  $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding utf8

  $healthy = $false
  for ($attempt = 0; $attempt -lt 60; $attempt += 1) {
    try {
      $ping = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/ping" -TimeoutSec 1
      $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
      $listenerPid = if ($listeners.Count) { [int]$listeners[0].OwningProcess } else { 0 }
      if (
        $ping.ok -and
        $ping.component -eq "nica-website-console" -and
        [int]$ping.api_version -eq 1 -and
        $listenerPid -gt 0 -and
        (Test-DescendantProcess -ProcessId $listenerPid -AncestorProcessId $proc.Id)
      ) {
        $manifest.serverPid = $listenerPid
        $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding utf8
        $healthy = $true
        break
      }
    } catch { }
    Start-Sleep -Milliseconds 250
  }
  if (-not $healthy) { throw "Website console did not become healthy with the expected API contract." }
} catch {
  if ($proc) { Stop-ProcessTreeBestEffort -RootProcessId $proc.Id }
  Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
  throw
}
$manifest | ConvertTo-Json -Depth 4
