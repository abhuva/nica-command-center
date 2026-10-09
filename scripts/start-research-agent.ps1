[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ResearchRepository,
  [Parameter(Mandatory = $true)][string]$DataDirectory,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [int]$Port = 8767,
  [string]$LauncherPath = "",
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$commandCenterRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedRepository = (Resolve-Path -LiteralPath $ResearchRepository).Path
$resolvedData = [System.IO.Path]::GetFullPath($DataDirectory)
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)
$componentState = Join-Path $resolvedState "research-agent"
$manifestPath = Join-Path $componentState "research-agent-process.json"
$resolvedLauncher = if ([string]::IsNullOrWhiteSpace($LauncherPath)) {
  Join-Path $resolvedRepository ".venv\Scripts\funding-agent.exe"
} else {
  [System.IO.Path]::GetFullPath($LauncherPath)
}

if ($Port -lt 1024 -or $Port -gt 65535) { throw "Research port must be between 1024 and 65535." }
if (-not (Test-Path -LiteralPath (Join-Path $resolvedRepository "pyproject.toml") -PathType Leaf)) {
  throw "ResearchRepository is not a Funding Observatory checkout."
}
if (-not (Test-Path -LiteralPath $resolvedLauncher -PathType Leaf)) {
  throw "Research launcher was not found: $resolvedLauncher"
}

function Get-ResearchHealth {
  try {
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/ping" -TimeoutSec 2
    if (
      [bool]$health.ok -and
      [string]$health.component -eq "funding-observatory" -and
      [int]$health.api_version -eq 1 -and
      [string]$health.backend -eq "codex"
    ) { return $health }
  } catch { }
  return $null
}

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

$existingHealth = Get-ResearchHealth
if ($existingHealth) {
  [ordered]@{
    component = "research-agent"
    outcome = "already-running"
    managed = Test-Path -LiteralPath $manifestPath -PathType Leaf
    port = $Port
    paused = [bool]$existingHealth.paused
    busy = [bool]$existingHealth.busy
  } | ConvertTo-Json -Depth 4
  return
}

$plan = [ordered]@{
  component = "research-agent"
  repository = $resolvedRepository
  dataDirectory = $resolvedData
  stateRoot = $resolvedState
  host = "127.0.0.1"
  port = $Port
  backend = "codex"
  launcher = $resolvedLauncher
  consequentialStartup = $true
}
$plan | ConvertTo-Json -Depth 4
if (-not $Apply) {
  Write-Host "Plan only. Starting this host may resume queued or scheduled research. Re-run with -Apply intentionally."
  return
}

if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
  throw "Research port $Port is occupied by a service without the expected health identity; no process was stopped."
}
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
  $stale = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $wrapper = Get-Process -Id ([int]$stale.pid) -ErrorAction SilentlyContinue
  $server = Get-Process -Id ([int]$stale.serverPid) -ErrorAction SilentlyContinue
  if ($wrapper -or $server) { throw "A research process manifest still refers to a live process; use the stop script first." }
  Remove-Item -LiteralPath $manifestPath -Force
}

New-Item -ItemType Directory -Force -Path $componentState | Out-Null
New-Item -ItemType Directory -Force -Path $resolvedData | Out-Null
$stdout = Join-Path $componentState "research-agent.out.log"
$stderr = Join-Path $componentState "research-agent.err.log"
$agentArguments = @(
  "--data-dir", ('"' + $resolvedData + '"'),
  "--backend", "codex",
  "serve", "--port", [string]$Port
) -join " "
$filePath = $resolvedLauncher
$argumentList = $agentArguments
if ([System.IO.Path]::GetExtension($resolvedLauncher) -ieq ".ps1") {
  $powershell = Get-Command powershell -ErrorAction Stop
  $filePath = $powershell.Source
  $argumentList = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ('"' + $resolvedLauncher + '"'), $agentArguments
  ) -join " "
}

$proc = $null
try {
  $proc = Start-Process -FilePath $filePath -ArgumentList $argumentList -WorkingDirectory $resolvedRepository -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
  $manifest = [ordered]@{
    component = "research-agent"
    repository = $commandCenterRoot
    researchRepository = $resolvedRepository
    dataDirectory = $resolvedData
    stateRoot = $resolvedState
    host = "127.0.0.1"
    port = $Port
    backend = "codex"
    pid = $proc.Id
    serverPid = $null
    apiVersion = 1
    launcher = $resolvedLauncher
    startedAt = (Get-Date).ToString("o")
    stdout = $stdout
    stderr = $stderr
  }
  $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding utf8

  $healthy = $false
  for ($attempt = 0; $attempt -lt 120; $attempt += 1) {
    $health = Get-ResearchHealth
    if ($health) {
      $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
      foreach ($listener in $listeners) {
        $listenerPid = [int]$listener.OwningProcess
        if ($listenerPid -eq $proc.Id -or (Test-DescendantProcess -ProcessId $listenerPid -AncestorProcessId $proc.Id)) {
          $manifest.serverPid = $listenerPid
          $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding utf8
          $healthy = $true
          break
        }
      }
    }
    if ($healthy) { break }
    if ($proc.HasExited) { throw "Research agent exited before it became healthy. Review $stderr" }
    Start-Sleep -Milliseconds 250
  }
  if (-not $healthy) { throw "Research agent did not become healthy with the expected API contract." }
} catch {
  if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
  throw
}
$manifest | ConvertTo-Json -Depth 4
