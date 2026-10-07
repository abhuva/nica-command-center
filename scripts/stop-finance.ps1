[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $true)][ValidateSet("nica", "tohu")][string]$FinanceId,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live")
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)
$manifestPath = Join-Path $resolvedState "finance\$FinanceId\finance-process.json"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  Write-Host "No $FinanceId finance process manifest found."
  return
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.repository -ne $repoRoot -or $manifest.component -ne "finance-$FinanceId") {
  throw "Finance process manifest belongs to a different repository or component."
}
$proc = Get-CimInstance Win32_Process -Filter "ProcessId = $($manifest.pid)" -ErrorAction SilentlyContinue
if ($proc) {
  $commandLine = [string]$proc.CommandLine
  if ($commandLine -notmatch '(?i)fava' -or $commandLine -notmatch ('--port\s+' + [regex]::Escape([string]$manifest.port))) {
    throw "PID $($manifest.pid) does not match the recorded Fava service."
  }
  if ($PSCmdlet.ShouldProcess("PID $($manifest.pid) ($FinanceId finance)", "Stop finance process")) {
    Stop-Process -Id $manifest.pid
    Wait-Process -Id $manifest.pid -Timeout 5 -ErrorAction SilentlyContinue
  }
}
if (Get-NetTCPConnection -LocalPort ([int]$manifest.port) -State Listen -ErrorAction SilentlyContinue) {
  throw "Finance port $($manifest.port) is still occupied; the manifest was retained."
}
Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
Write-Host "$FinanceId finance service is stopped; its ledger was not changed."
