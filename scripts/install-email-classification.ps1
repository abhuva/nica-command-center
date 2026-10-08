[CmdletBinding()]
param(
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [ValidateSet("gliclass-multilang-mini", "gliclass-multilang-edge")]
  [string]$Model = "gliclass-multilang-mini",
  [string]$TorchIndexUrl = "",
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)
$repoPrefix = $repoRoot.TrimEnd('\') + '\'
if ($resolvedState -eq $repoRoot -or $resolvedState.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "Classification state must be outside the repository."
}
if (-not [string]::IsNullOrWhiteSpace($TorchIndexUrl)) {
  $torchUri = $null
  if (-not [Uri]::TryCreate($TorchIndexUrl, [UriKind]::Absolute, [ref]$torchUri) -or
      $torchUri.Scheme -ne "https" -or
      $torchUri.Host -ne "download.pytorch.org") {
    throw "TorchIndexUrl must be an HTTPS wheel index on download.pytorch.org."
  }
}

$classificationRoot = Join-Path $resolvedState "email\classification"
$venvRoot = Join-Path $classificationRoot ".venv"
$venvPython = Join-Path $venvRoot "Scripts\python.exe"
$modelCache = Join-Path $classificationRoot "models"
$plan = [ordered]@{
  component = "email-classification-model"
  action = if ($Apply) { "apply" } else { "preview" }
  stateRoot = $resolvedState
  environment = $venvRoot
  modelCache = $modelCache
  model = $Model
  package = "gliclass==0.1.20"
  torchIndexUrl = if ([string]::IsNullOrWhiteSpace($TorchIndexUrl)) { "PyPI CPU default" } else { $TorchIndexUrl }
  downloadTransport = "standard-http-ipv4"
  loadCheck = "deferred-to-classification-run"
}
if (-not $Apply) {
  $plan | ConvertTo-Json -Depth 4
  exit 0
}

New-Item -ItemType Directory -Path $classificationRoot -Force | Out-Null
if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
  & python -m venv $venvRoot
  if ($LASTEXITCODE -ne 0) { throw "Could not create the classification virtual environment." }
}
if (-not [string]::IsNullOrWhiteSpace($TorchIndexUrl)) {
  & $venvPython -m pip install --disable-pip-version-check --upgrade --force-reinstall torch --index-url $TorchIndexUrl
  if ($LASTEXITCODE -ne 0) { throw "Could not install PyTorch from the requested compute-platform index." }
}
& $venvPython -m pip install --disable-pip-version-check -r (Join-Path $repoRoot "Email\requirements-classification.txt")
if ($LASTEXITCODE -ne 0) { throw "Could not install classification dependencies." }
$env:HF_HOME = $modelCache
$env:HF_HUB_DOWNLOAD_TIMEOUT = "600"
$env:HF_HUB_DISABLE_XET = "1"
$operatingSystem = Get-CimInstance Win32_OperatingSystem
$freeMemoryMB = [math]::Round($operatingSystem.FreePhysicalMemory / 1KB)
if ($freeMemoryMB -lt 1024) {
  Write-Warning "Only $freeMemoryMB MB of physical memory is currently free. The download can continue, but close other applications before running the model."
}
& $venvPython (Join-Path $repoRoot "Email\download_classification_model.py") --model $Model --prefer-ipv4
if ($LASTEXITCODE -ne 0) { throw "Could not download the classification model." }
$plan.action = "installed"
$plan.freeMemoryMB = $freeMemoryMB
$plan | ConvertTo-Json -Depth 4
