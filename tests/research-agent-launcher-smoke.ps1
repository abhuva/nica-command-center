$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("nica-research-agent-" + [Guid]::NewGuid().ToString("N"))
$research = Join-Path $sandbox "research"
$state = Join-Path $sandbox "state"
$data = Join-Path $sandbox "private-data"
$launcherDir = Join-Path $research ".venv\Scripts"

function Get-FreePort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  try { return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port } finally { $listener.Stop() }
}

try {
  New-Item -ItemType Directory -Force -Path $launcherDir | Out-Null
  Set-Content -LiteralPath (Join-Path $research "pyproject.toml") -Value '[project]' -Encoding utf8
  @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AgentArguments)
$portIndex = [Array]::IndexOf($AgentArguments, "--port")
if ($portIndex -lt 0) { throw "Synthetic research port missing" }
& node (Join-Path $PSScriptRoot "fake-research.mjs") --port $AgentArguments[$portIndex + 1]
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath (Join-Path $launcherDir "funding-agent.ps1") -Encoding utf8
  @'
import fs from "node:fs";
import http from "node:http";

const portIndex = process.argv.indexOf("--port");
const port = Number(process.argv[portIndex + 1]);
const busyFlag = new URL("busy.flag", import.meta.url);
const server = http.createServer((request, response) => {
  if (request.url === "/api/ping") {
    const body = JSON.stringify({
      ok: true,
      component: "funding-observatory",
      api_version: 1,
      backend: "codex",
      paused: true,
      busy: fs.existsSync(busyFlag),
      worker_state: fs.existsSync(busyFlag) ? "researching" : "paused"
    });
    response.writeHead(200, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) });
    response.end(body);
    return;
  }
  response.writeHead(404);
  response.end();
});
server.listen(port, "127.0.0.1");
'@ | Set-Content -LiteralPath (Join-Path $launcherDir "fake-research.mjs") -Encoding utf8

  $port = Get-FreePort
  $start = Join-Path $repoRoot "scripts\start-research-agent.ps1"
  $stop = Join-Path $repoRoot "scripts\stop-research-agent.ps1"
  $launcher = Join-Path $launcherDir "funding-agent.ps1"
  $manifestPath = Join-Path $state "research-agent\research-agent-process.json"

  & $start -ResearchRepository $research -DataDirectory $data -StateRoot $state -Port $port -LauncherPath $launcher | Out-Null
  if (Test-Path -LiteralPath $manifestPath) { throw "Plan-only research startup wrote a manifest." }

  & $start -ResearchRepository $research -DataDirectory $data -StateRoot $state -Port $port -LauncherPath $launcher -Apply | Out-Null
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  if (
    $manifest.component -ne "research-agent" -or
    [string]$manifest.researchRepository -ne (Resolve-Path -LiteralPath $research).Path -or
    [string]$manifest.dataDirectory -ne [System.IO.Path]::GetFullPath($data) -or
    [int]$manifest.serverPid -le 0
  ) { throw "Research manifest did not describe the synthetic owned process." }
  $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/ping" -TimeoutSec 3
  if (-not $health.ok -or $health.component -ne "funding-observatory" -or $health.backend -ne "codex") {
    throw "Synthetic research service did not expose the expected health contract."
  }

  $busyFlag = Join-Path $launcherDir "busy.flag"
  Set-Content -LiteralPath $busyFlag -Value "synthetic active research" -Encoding utf8
  $blocked = $false
  try { & $stop -StateRoot $state | Out-Null } catch { $blocked = $_.Exception.Message -match "active" }
  if (-not $blocked -or -not (Test-Path -LiteralPath $manifestPath)) {
    throw "Research stop did not preserve a busy managed process."
  }
  Remove-Item -LiteralPath $busyFlag -Force

  & $stop -StateRoot $state | Out-Null
  if (Test-Path -LiteralPath $manifestPath) { throw "Research stop retained its manifest." }
  if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) {
    throw "Synthetic research service remained on its port after stop."
  }
  Write-Output "Research agent launcher smoke check OK"
} finally {
  $manifestPath = Join-Path $state "research-agent\research-agent-process.json"
  if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    try { & (Join-Path $repoRoot "scripts\stop-research-agent.ps1") -StateRoot $state | Out-Null } catch { }
  }
  if (Test-Path -LiteralPath $sandbox) {
    $resolvedSandbox = [System.IO.Path]::GetFullPath($sandbox)
    $tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedSandbox.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Synthetic research sandbox escaped the temporary directory."
    }
    Remove-Item -LiteralPath $resolvedSandbox -Recurse -Force
  }
}
