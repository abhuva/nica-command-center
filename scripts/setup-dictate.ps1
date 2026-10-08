[CmdletBinding()]
param(
  [string[]]$Models = @("multilingual"),
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA "NICA\CommandCenter\live"),
  [string]$PythonExecutable = "python",
  [string]$ArtifactCache = "",
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$resolvedState = [System.IO.Path]::GetFullPath($StateRoot)
$componentState = Join-Path $resolvedState "dictate"
$runtimeRoot = Join-Path $componentState "runtime"
$venvRoot = Join-Path $runtimeRoot ".venv"
$modelsRoot = Join-Path $componentState "models"
$manifestPath = Join-Path $componentState "install.json"
$registryPath = Join-Path $repoRoot "Dictate\model-registry.json"
$requirementsPath = Join-Path $repoRoot "Dictate\requirements-windows.lock"
$registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
if ([int]$registry.schemaVersion -ne 1) { throw "Unsupported Dictate model registry." }

$modelIds = @(
  $Models |
    ForEach-Object { [string]$_ -split "," } |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ } |
    Select-Object -Unique
)
foreach ($modelId in $modelIds) {
  if ($modelId -notin @("multilingual", "german")) {
    throw "Dictate model '$modelId' is not supported. Choose multilingual or german."
  }
}
$selectedModels = @(
  foreach ($modelId in $modelIds) {
    $model = @($registry.models | Where-Object { [string]$_.id -eq $modelId })
    if ($model.Count -ne 1) { throw "Dictate model '$modelId' is not registered." }
    $model[0]
  }
)

function Test-RegisteredModel {
  param([Parameter(Mandatory = $true)]$Model, [Parameter(Mandatory = $true)][string]$Directory)
  if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return $false }
  foreach ($file in $Model.files) {
    $path = Join-Path $Directory ([string]$file.name)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $path
    if ([long]$item.Length -ne [long]$file.bytes) { return $false }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne [string]$file.sha256) { return $false }
  }
  return $true
}

$plan = [ordered]@{
  component = "dictate-setup"
  repository = $repoRoot
  localState = $componentState
  runtime = $venvRoot
  models = @($selectedModels | ForEach-Object {
    [ordered]@{
      id = [string]$_.id
      destination = Join-Path $modelsRoot ([string]$_.id)
      bytes = [long](($_.files | Measure-Object -Property bytes -Sum).Sum)
      installed = Test-RegisteredModel $_ (Join-Path $modelsRoot ([string]$_.id))
      license = [string]$_.license
      source = [string]$_.source
      revision = [string]$_.revision
    }
  })
  artifactCache = if ([string]::IsNullOrWhiteSpace($ArtifactCache)) { $null } else { [System.IO.Path]::GetFullPath($ArtifactCache) }
}
$plan | ConvertTo-Json -Depth 6
if (-not $Apply) {
  Write-Host "Plan only. Re-run with -Apply to create the local runtime and install verified model artifacts."
  return
}

if ($env:OS -ne "Windows_NT") { throw "The Dictate capability currently supports Windows only." }
$python = Get-Command $PythonExecutable -ErrorAction Stop
$versionText = & $python.Source --version 2>&1
if ($LASTEXITCODE -ne 0 -or $versionText -notmatch 'Python\s+(\d+)\.(\d+)') {
  throw "Could not determine the configured Python version."
}
if ([int]$Matches[1] -lt 3 -or ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -lt 10)) {
  throw "Dictate requires Python 3.10 or newer."
}

New-Item -ItemType Directory -Force -Path $componentState, $runtimeRoot, $modelsRoot | Out-Null
if (-not (Test-Path -LiteralPath (Join-Path $venvRoot "Scripts\python.exe") -PathType Leaf)) {
  & $python.Source -m venv $venvRoot
  if ($LASTEXITCODE -ne 0) { throw "Could not create the Dictate Python environment." }
}
$venvPython = Join-Path $venvRoot "Scripts\python.exe"
& $venvPython -m pip install --disable-pip-version-check --requirement $requirementsPath
if ($LASTEXITCODE -ne 0) { throw "Could not install Dictate's pinned Python dependencies." }

$installed = [System.Collections.Generic.List[object]]::new()
foreach ($model in $selectedModels) {
  $modelId = [string]$model.id
  $destination = Join-Path $modelsRoot $modelId
  if (Test-RegisteredModel $model $destination) {
    $installed.Add([ordered]@{ id = $modelId; outcome = "already-installed"; path = $destination })
    continue
  }

  $stageParent = Join-Path $componentState ".staging"
  $stage = Join-Path $stageParent ($modelId + "-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  try {
    foreach ($file in $model.files) {
      $name = [string]$file.name
      $target = Join-Path $stage $name
      $cacheFile = if ([string]::IsNullOrWhiteSpace($ArtifactCache)) {
        $null
      } else {
        Join-Path ([System.IO.Path]::GetFullPath($ArtifactCache)) (Join-Path $modelId $name)
      }
      if ($cacheFile -and (Test-Path -LiteralPath $cacheFile -PathType Leaf)) {
        Copy-Item -LiteralPath $cacheFile -Destination $target
      } else {
        Write-Host "Downloading Dictate model artifact $modelId/$name"
        Invoke-WebRequest -UseBasicParsing -Uri ([string]$file.url) -OutFile $target
      }
    }
    if (-not (Test-RegisteredModel $model $stage)) {
      throw "Downloaded Dictate model '$modelId' failed size or SHA-256 verification."
    }
    if (Test-Path -LiteralPath $destination) {
      $recoveryRoot = Join-Path $componentState "recovery"
      New-Item -ItemType Directory -Force -Path $recoveryRoot | Out-Null
      $recovery = Join-Path $recoveryRoot ($modelId + "-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
      Move-Item -LiteralPath $destination -Destination $recovery
    }
    Move-Item -LiteralPath $stage -Destination $destination
    $installed.Add([ordered]@{ id = $modelId; outcome = "installed"; path = $destination })
  } finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
  }
}

$manifest = [ordered]@{
  version = 1
  component = "dictate-install"
  repository = $repoRoot
  stateRoot = $resolvedState
  python = $versionText.ToString().Trim()
  requirements = (Get-FileHash -LiteralPath $requirementsPath -Algorithm SHA256).Hash.ToLowerInvariant()
  models = @($installed)
  installedAt = (Get-Date).ToString("o")
}
$temporaryManifest = $manifestPath + ".tmp"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($temporaryManifest, (($manifest | ConvertTo-Json -Depth 6) + [Environment]::NewLine), $utf8NoBom)
Move-Item -LiteralPath $temporaryManifest -Destination $manifestPath -Force
$manifest | ConvertTo-Json -Depth 6
