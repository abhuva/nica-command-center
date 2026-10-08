$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("nica-dictate-smoke-" + [guid]::NewGuid().ToString("N"))
$state = Join-Path $sandbox "state"

try {
  $registryPath = Join-Path $repoRoot "Dictate\model-registry.json"
  $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
  if ([int]$registry.schemaVersion -ne 1) { throw "Unexpected Dictate model registry version." }
  $models = @($registry.models)
  if (@($models | ForEach-Object { [string]$_.id }) -join "," -ne "multilingual,german") {
    throw "Dictate registry must contain the multilingual and German models in that order."
  }
  foreach ($model in $models) {
    if ([string]$model.license -ne "CC-BY-4.0" -or [string]::IsNullOrWhiteSpace([string]$model.revision)) {
      throw "Dictate model provenance is incomplete."
    }
    foreach ($file in $model.files) {
      if ([long]$file.bytes -lt 1 -or [string]$file.sha256 -notmatch '^[a-f0-9]{64}$' -or [string]$file.url -notmatch '^https://') {
        throw "Dictate model file metadata is invalid."
      }
    }
  }

  $setupOutput = (& (Join-Path $repoRoot "scripts\setup-dictate.ps1") -Models multilingual,german -StateRoot $state | Out-String)
  if ($setupOutput -notmatch '"component"\s*:\s*"dictate-setup"') {
    throw "Dictate setup did not produce the expected preview."
  }
  if (Test-Path -LiteralPath $state) { throw "Dictate setup preview wrote local state." }

  $settings = Get-Content -LiteralPath (Join-Path $repoRoot "config\settings.default.json") -Raw | ConvertFrom-Json
  if ([int]$settings.schemaVersion -ne 3 -or [bool]$settings.startup.services.dictate) {
    throw "Dictate must be represented in settings and disabled by default."
  }
  if ([string]$settings.dictate.model -ne "multilingual" -or [string]$settings.dictate.hotkey -ne "ctrl" -or [double]$settings.dictate.minHoldSeconds -ne 2.0) {
    throw "Dictate defaults are not the accepted multilingual Ctrl/two-second profile."
  }

  $python = Get-Command python -ErrorAction Stop
  & $python.Source -m py_compile `
    (Join-Path $repoRoot "Dictate\runner.py") `
    (Join-Path $repoRoot "Dictate\upstream\core.py") `
    (Join-Path $repoRoot "Dictate\upstream\gui.py") `
    (Join-Path $repoRoot "Dictate\upstream\local_stt.py")
  if ($LASTEXITCODE -ne 0) { throw "Dictate Python sources did not compile." }

  $runnerSource = Get-Content -LiteralPath (Join-Path $repoRoot "Dictate\runner.py") -Raw
  if ($runnerSource -notmatch 'do_not_retain_failed_audio' -or $runnerSource -notmatch '"provider": "parakeet_local"') {
    throw "Dictate privacy controls are not visible in the adapter."
  }
  Write-Host "Dictate smoke check OK"
} finally {
  if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
}
