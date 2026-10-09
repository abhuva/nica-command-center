# ADR-009: Manage desktop dictation as an optional local capability

**Status**: Accepted

**Date**: 2026-10-08

**Participants**: Marc Bielert and Codex-assisted implementation work

## Context

NICA wants push-to-talk dictation in whichever Windows text field currently has
focus. Testing `winidi/dictate` established that global key capture, microphone
recording, local `sherpa-onnx` transcription, and direct text injection work on
the current workstation after applying its pending Windows startup fix.

The German Primeline model provides the strongest tested German behavior. The
multilingual NVIDIA Parakeet model handles both German and English and is the
better default for bilingual use. Each model is roughly 640 MB and a loaded
recognizer uses substantial memory. Loading both at once failed during testing.

The capability is useful to an individual workstation but is not authoritative
for organisational data. Bundling model weights in Git or the Nextcloud vault
would violate the repository's software/state boundary and would impose a
large dependency on users who do not want dictation.

This decision builds on [ADR-002](ADR-002-explicit-vault-and-local-state-roots.md)
and [ADR-005](ADR-005-use-a-repository-owned-workspace-launcher.md).

## Decision

We decided to manage Dictate as an optional, Windows-only background capability
with an independent process lifecycle.

The repository owns:

- a pinned and attributed snapshot of the small upstream application;
- a NICA adapter that enforces local-only model use and privacy defaults;
- a versioned model registry containing source revisions, sizes, licenses, and
  SHA-256 digests;
- plan/apply installation and lifecycle scripts;
- launcher, settings, diagnostics, tests, and documentation.

The machine-local state root owns the Python environment, downloaded models,
process manifests, readiness records, settings, and logs. Models are installed
explicitly and verified before publication. Disabling Dictate stops its process
but retains installed models so it can be re-enabled without another download.

The default model is multilingual Parakeet. Primeline German is an optional
installed alternative. Switching models restarts only Dictate: the old process
exits and releases its recognizer before the new process loads and warms the
selected model. A failed switch attempts to restore the previous model.

The initial capability uses direct operating-system keyboard injection into the
currently focused field. It retains neither transcript history nor failed audio.
Cloud transcription providers are outside this decision and remain disabled.

## Alternatives considered

### Commit model files or use Git LFS

This would make checkout size and licensing obligations unavoidable and would
mix replaceable third-party artifacts with source. It was rejected.

### Store models in the shared vault

This would consume synchronized storage and make Nextcloud distribute local
runtime dependencies. It was rejected because models are rebuildable local
artifacts, not organisational records.

### Load both models and switch an in-process pointer

This could reduce switch latency but caused memory-allocation failure during
the workstation test and would double steady-state memory. It was rejected in
favor of a bounded process restart.

### Reimplement the tool inside Homepage

This would couple a desktop microphone and global keyboard hook to the web
control surface and expand Homepage's failure domain. It was rejected in favor
of adapting the existing tool as an independent process.

### Require a separate manual installation

This would preserve upstream ownership but make command-centre setup incomplete
and non-reproducible. It was rejected in favor of an optional installer using
pinned dependencies and verified model artifacts.

## Consequences

- (+) Users who enable Dictate get one-button workspace startup and controlled
  model selection.
- (+) Users who do not enable it download no model and consume no Dictate RAM.
- (+) German and multilingual models remain replaceable, attributed artifacts.
- (+) Dictate failure does not prevent Homepage or other services from running.
- (+) No audio or transcript is intentionally retained after successful or
  failed recognition.
- (-) Initial installation downloads roughly 640 MB per selected model.
- (-) Model switching causes an expected interruption while the process restarts
  and warms the replacement model.
- (-) The first implementation is Windows-specific and depends on synthetic
  keyboard input accepted by the focused application.
- (=) The focused application remains authoritative for inserted text; Dictate
  does not become a source of truth for that content.
