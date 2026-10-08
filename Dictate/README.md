# NICA Dictate

NICA Dictate is an optional Windows desktop capability managed by the command
centre. Hold the configured key, speak for at least the configured minimum,
release it, and the locally transcribed text is typed into the focused field.

The repository contains the adapter and an attributed, pinned snapshot of
[`winidi/dictate`](https://github.com/winidi/dictate). Speech models and the
Python runtime are machine-local artifacts below `NICA_STATE_ROOT`; they are
never committed or stored in the Nextcloud vault.

## Install models and runtime

Prerequisites are Windows, Python 3.10 or newer on `PATH`, about 1.5 GB free
disk space for both models plus the local Python environment, and internet
access for the first installation. A second computer therefore receives the
source through the normal command-centre checkout, then builds its own local
runtime and downloads the selected model artifacts with this command. No model
file is copied through Git or Nextcloud.

Preview first, then apply:

```powershell
.\scripts\setup-dictate.ps1 -Models multilingual,german
.\scripts\setup-dictate.ps1 -Models multilingual,german -Apply
```

`multilingual` is the default and automatically recognizes German, English,
and 23 other European languages. `german` is the Primeline German fine-tune.
Both models together require about 1.3 GB. Only the active model is loaded into
memory. The installer pins Python packages and model revisions and verifies
every model file by size and SHA-256 before making it available. Re-running the
preview is also a full integrity check of already installed models.

For an offline or centrally cached installation, place the registered files in
`<cache>\multilingual` and/or `<cache>\german`, then add
`-ArtifactCache <cache>`. Missing cache files are downloaded normally.

## Start, switch, and stop

```powershell
.\scripts\start-dictate.ps1 -Model multilingual
.\scripts\start-dictate.ps1 -Model multilingual -Apply
.\scripts\switch-dictate-model.ps1 -Model german
.\scripts\switch-dictate-model.ps1 -Model german -Apply
.\scripts\stop-dictate.ps1
```

Homepage Settings controls whether Dictate starts during workspace startup and
which installed model is selected. Re-running the workspace launcher applies a
changed model by restarting only Dictate.

The adapter disables upstream failed-audio retention and does not keep a
transcript history. Diagnostic logs contain timings, levels, and character
counts, not transcribed text.

## Upstream provenance

The files below `upstream/` are from `winidi/dictate` pull request revision
`b3aa938e6c6c120f4fd54c6d0ad4c791af79261a`, which includes the Windows
single-instance-lock fix. Upstream is MIT licensed; its license and README are
retained in that directory. Model attribution and pinned revisions are stored
in `model-registry.json`.
