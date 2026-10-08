$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("nica-website-console-" + [Guid]::NewGuid().ToString("N"))
$website = Join-Path $sandbox "website"
$state = Join-Path $sandbox "state"
$tools = Join-Path $website "tools"

function Get-FreePort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  try { return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port } finally { $listener.Stop() }
}

try {
  New-Item -ItemType Directory -Force -Path $tools | Out-Null
  @'
param([string]$HostAddress = "127.0.0.1", [int]$Port = 8787)
& node (Join-Path $PSScriptRoot "fake-console.mjs") --host $HostAddress --port $Port
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath (Join-Path $tools "dev_console.ps1") -Encoding utf8
  @'
import fs from "node:fs";
import http from "node:http";

const portIndex = process.argv.indexOf("--port");
const hostIndex = process.argv.indexOf("--host");
const port = Number(process.argv[portIndex + 1]);
const host = String(process.argv[hostIndex + 1]);
const server = http.createServer((request, response) => {
  if (request.url === "/api/ping") {
    const body = JSON.stringify({
      ok: true,
      component: "nica-website-console",
      api_version: 1,
      busy: fs.existsSync(new URL("busy.flag", import.meta.url)),
    });
    response.writeHead(200, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) });
    response.end(body);
    return;
  }
  response.writeHead(404);
  response.end();
});
server.listen(port, host);
'@ | Set-Content -LiteralPath (Join-Path $tools "fake-console.mjs") -Encoding utf8

  $port = Get-FreePort
  $start = Join-Path $repoRoot "scripts\start-website-console.ps1"
  $stop = Join-Path $repoRoot "scripts\stop-website-console.ps1"
  $manifestPath = Join-Path $state "website-console\website-console-process.json"

  & $start -WebsiteRepository $website -StateRoot $state -Port $port | Out-Null
  if (Test-Path -LiteralPath $manifestPath) {
    throw "Plan-only website console startup wrote a process manifest."
  }

  & $start -WebsiteRepository $website -StateRoot $state -Port $port -Apply | Out-Null
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Website console startup did not write its process manifest."
  }
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  if (
    $manifest.component -ne "website-console" -or
    [string]$manifest.websiteRepository -ne (Resolve-Path -LiteralPath $website).Path -or
    [int]$manifest.serverPid -le 0
  ) {
    throw "Website console manifest does not describe the synthetic process."
  }
  $ping = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/ping" -TimeoutSec 3
  if (-not $ping.ok -or $ping.component -ne "nica-website-console" -or [int]$ping.api_version -ne 1) {
    throw "Synthetic website console did not expose the expected health contract."
  }

  $busyFlag = Join-Path $tools "busy.flag"
  Set-Content -LiteralPath $busyFlag -Value "synthetic active operation" -Encoding utf8
  $blocked = $false
  try {
    & $stop -StateRoot $state | Out-Null
  } catch {
    $blocked = $_.Exception.Message -match "busy"
  }
  if (-not $blocked -or -not (Test-Path -LiteralPath $manifestPath)) {
    throw "Website console stop did not preserve a busy synthetic process."
  }
  Remove-Item -LiteralPath $busyFlag -Force

  & $stop -StateRoot $state | Out-Null
  if (Test-Path -LiteralPath $manifestPath) {
    throw "Website console stop retained its process manifest."
  }
  if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) {
    throw "Synthetic website console remained on its port after stop."
  }
  Write-Output "Website console launcher smoke check OK"
} finally {
  $manifestPath = Join-Path $state "website-console\website-console-process.json"
  if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    try { & (Join-Path $repoRoot "scripts\stop-website-console.ps1") -StateRoot $state | Out-Null } catch { }
  }
  if (Test-Path -LiteralPath $sandbox) {
    $resolvedSandbox = [System.IO.Path]::GetFullPath($sandbox)
    $tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedSandbox.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Synthetic website-console sandbox escaped the temporary directory."
    }
    Remove-Item -LiteralPath $resolvedSandbox -Recurse -Force
  }
}
