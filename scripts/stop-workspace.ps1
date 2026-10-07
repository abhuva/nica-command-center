[CmdletBinding()]
param(
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [switch]$NotifyOnError
)

$ErrorActionPreference = "Continue"
$results = [System.Collections.Generic.List[object]]::new()
$stops = @(
  @{ name = "finance-tohu"; script = "stop-finance.ps1"; args = @{ FinanceId = "tohu"; StateRoot = $StateRoot } },
  @{ name = "finance-nica"; script = "stop-finance.ps1"; args = @{ FinanceId = "nica"; StateRoot = $StateRoot } },
  @{ name = "email"; script = "stop-email.ps1"; args = @{ StateRoot = $StateRoot } },
  @{ name = "vaultgraph"; script = "stop-vaultgraph.ps1"; args = @{ StateRoot = $StateRoot } },
  @{ name = "calendar"; script = "stop-calendar-read.ps1"; args = @{ StateRoot = $StateRoot } },
  @{ name = "homepage"; script = "stop-homepage.ps1"; args = @{ StateRoot = $StateRoot } }
)
foreach ($entry in $stops) {
  try {
    $arguments = $entry.args
    & (Join-Path $PSScriptRoot $entry.script) @arguments | Out-Null
    $results.Add([ordered]@{ service = $entry.name; outcome = "stopped-or-absent" })
  } catch {
    $results.Add([ordered]@{ service = $entry.name; outcome = "failed"; error = $_.Exception.Message })
  }
}
$failed = @($results | Where-Object { $_.outcome -eq "failed" })
$result = [ordered]@{ ok = $failed.Count -eq 0; stoppedAt = (Get-Date).ToString("o"); results = @($results) }
$result | ConvertTo-Json -Depth 6
if ($failed.Count) {
  if ($NotifyOnError) {
    try { (New-Object -ComObject WScript.Shell).Popup("Workspace shutdown had $($failed.Count) failure(s).", 0, "NICA Command Centre", 48) | Out-Null } catch { }
  }
  throw "Workspace shutdown completed with $($failed.Count) failure(s)."
}
