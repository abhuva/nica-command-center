[CmdletBinding(SupportsShouldProcess = $true)]
param([string]$SandboxRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\beantime-shadow"))

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedSandbox = [System.IO.Path]::GetFullPath($SandboxRoot)
$manifestPath = Join-Path $resolvedSandbox "state\homepage\beantime-shadow-process.json"

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  Write-Host "No Beantime synthetic-shadow process manifest found."
  exit 0
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.repository -ne $repoRoot -or $manifest.component -ne "beantime-synthetic-shadow" -or -not [bool]$manifest.synthetic) {
  throw "Beantime process manifest belongs to a different repository or component."
}

$proc = Get-CimInstance Win32_Process -Filter "ProcessId = $($manifest.pid)" -ErrorAction SilentlyContinue
if ($proc) {
  $expectedServer = (Join-Path $repoRoot "serve.mjs").ToLowerInvariant()
  $commandLine = [string]$proc.CommandLine
  if ($commandLine.ToLowerInvariant().IndexOf($expectedServer, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw "PID $($manifest.pid) does not match this repository's Homepage server."
  }

  $children = @(Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $manifest.pid })
  $favaChildren = @($children | Where-Object { ([string]$_.CommandLine) -match '(?i)fava' })
  $unexpectedChildren = @(
    $children | Where-Object {
      $_.Name -ne "conhost.exe" -and $_.ProcessId -notin @($favaChildren.ProcessId)
    }
  )
  if ($unexpectedChildren.Count) {
    throw "Beantime shadow has an unexpected child process; no process was stopped."
  }

  if ($PSCmdlet.ShouldProcess("PID $($manifest.pid) (Beantime synthetic shadow)", "Stop process")) {
    foreach ($child in $favaChildren) {
      Stop-Process -Id $child.ProcessId -ErrorAction SilentlyContinue
      Wait-Process -Id $child.ProcessId -Timeout 5 -ErrorAction SilentlyContinue
    }
    Stop-Process -Id $manifest.pid -ErrorAction SilentlyContinue
    Wait-Process -Id $manifest.pid -Timeout 5 -ErrorAction SilentlyContinue
  }
}

foreach ($port in @([int]$manifest.homepagePort, [int]$manifest.favaPort)) {
  if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) {
    throw "Beantime shadow port $port is still occupied; the manifest was retained."
  }
}

Remove-Item -LiteralPath $manifestPath -Force
Write-Host "Beantime synthetic shadow is stopped; its isolated ledger and timer state were retained."
