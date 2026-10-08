# Local email classification: workstation handoff

**Status:** Implementation complete; inference validation paused for a more
capable workstation

**Branch:** `feature/email-local-classification`

**Date:** 2026-10-08

## Why work is paused

The development computer has 5.94 GB of system RAM and an NVIDIA GeForce GTX
1050 Ti with 4 GB VRAM. During installation only 128-292 MB of physical memory
was free. The default PyPI installation also selected CPU-only PyTorch, so this
computer does not represent the intended office deployment with 16 GB VRAM.

The GLiClass Multilang Mini snapshot was downloaded and structurally checked,
but it was deliberately not loaded for inference on this computer. Loading it
under severe memory pressure would not provide a useful benchmark and could
destabilize unrelated applications.

## Implemented scope

- A shadow-only Classification tab can run a transparent keyword baseline,
  GLiClass Multilang Mini, or GLiClass Multilang Edge.
- Model runs, predictions, score maps, configuration, input hashes, progress,
  failures, and resolved model revisions are retained separately.
- Human spam and mail-type labels are separate from model output and have an
  append-only event history.
- A stable 20-percent blind holdout hides predictions until the first human
  label.
- Labels can be exported without message content or, with an explicit warning,
  as confidential training data with content.
- Classification never changes mailbox state, tags, `include_state`, or vault
  exports. Remote filtering remains out of scope.
- Optional Python dependencies and model weights live below the configured
  machine-local state root and are never committed or synchronized.
- The installer supports preview/apply, validates its state boundary, resumes
  cached downloads, warns about low free memory, and can replace CPU-only
  PyTorch with a build from an explicitly selected official CUDA wheel index.

The evidence and data-ownership decision is recorded in
[ADR-007](adr/ADR-007-separate-email-predictions-from-human-annotations.md).

## Local artifacts are not portable

The Git branch contains code, tests, and documentation only. The virtual
environment and weights on this computer are disposable local state under:

```text
NICA_STATE_ROOT/email/classification/.venv
NICA_STATE_ROOT/email/classification/models
```

Do not copy those directories through Git or Nextcloud. Recreate them on the
target workstation with the installer. Email messages and human labels remain
in the local Email SQLite database; export labels before replacing that
database because human review cannot be reconstructed from the mail servers.

## Verified on the development computer

- `gliclass==0.1.20` and its dependencies installed in the isolated runtime.
- `knowledgator/gliclass-multilang-mini` revision
  `0bd888b6c3ef9fca5f0a9d407bddfbbc7623486b` downloaded successfully.
- `model.safetensors` is 567,503,348 bytes and its header exposes 227 tensors.
- The downloader can reopen the cached snapshot without network access.
- `npm run check:email-classification-shadow` passes with synthetic messages.
- Python compilation, PowerShell parsing, diff checks, and the pre-commit
  Gitleaks scan pass.

No real email content was added to fixtures, logs, documentation, or Git.

## Installation on the office computer

1. Check out this feature branch and confirm that Python and the NVIDIA driver
   are available:

   ```powershell
   git switch feature/email-local-classification
   git pull --ff-only
   python --version
   nvidia-smi
   ```

2. On the official PyTorch installer, select Windows, Pip, Python, and the CUDA
   platform appropriate for that computer. Copy only the wheel-index URL from
   the generated command. Preview the NICA installation before applying it:

   ```powershell
   .\scripts\install-email-classification.ps1 `
     -Model gliclass-multilang-mini `
     -TorchIndexUrl "https://download.pytorch.org/whl/cu126"

   .\scripts\install-email-classification.ps1 `
     -Model gliclass-multilang-mini `
     -TorchIndexUrl "https://download.pytorch.org/whl/cu126" `
     -Apply
   ```

   `cu126` is an example, not a permanent project pin. Use the current official
   selector result. The installer accepts only HTTPS indexes hosted by
   `download.pytorch.org`.

3. Confirm the final installer JSON contains:

   ```json
   {
     "cudaAvailable": true,
     "cudaDevice": "the expected office GPU"
   }
   ```

   Stop here if CUDA remains unavailable; do not interpret a CPU run as a
   benchmark for the office GPU.

4. Run the synthetic boundary check:

   ```powershell
   npm run check:email-classification-shadow
   ```

5. Start the normal Email runtime through the existing workspace launcher, or
   preview and apply the Email launcher directly:

   ```powershell
   .\scripts\start-email.ps1 -VaultRoot "C:\path\to\vault"
   .\scripts\start-email.ps1 -VaultRoot "C:\path\to\vault" -Apply
   ```

## First inference validation

Keep the first run deliberately small and local:

1. Open the Classification tab and confirm that Mini is available and reports
   the expected CUDA device.
2. Select `auto` as the device, choose a limit of 10-25 messages, and start a
   Mini shadow run.
3. Record load time, classification time, peak system RAM, and peak VRAM. Do
   not add message text to benchmark notes or logs.
4. Confirm the run completes, stores a resolved model revision, and leaves
   mailbox state, tags, include/exclude state, and vault files unchanged.
5. Review German and English examples in the normal queue. Label holdout
   examples only in the blind queue before revealing predictions.
6. Repeat the same bounded selection with Edge if a speed/quality comparison is
   useful. Do not compare models on different message selections.
7. Export the content-free labels as the first backup. Keep any content-bearing
   training export in protected local storage outside Git and Nextcloud.
8. Verify the Classification UI at desktop and narrow width and check the
   browser console for errors.

## Acceptance criteria before merging

- CUDA is available on the intended 16-GB-VRAM workstation.
- Mini loads and completes a bounded run without exhausting system RAM or VRAM.
- German and English messages both produce usable review candidates.
- A repeated run records predictions without changing remote or export state.
- Human labels survive restart and can be exported and re-imported.
- The blind holdout behaves as documented.
- Edge and Mini can be compared on the same message selection.
- Synthetic regression checks and browser-level verification pass on the
  target workstation.

Automatic spam actions, mailbox moves, deletion, provider spam reporting, and
training a new model remain separate future decisions. Prediction quality must
be measured first.

## Known installation diagnostics

The first Mini download failed in Hugging Face's Xet transfer path while trying
to allocate roughly 64 MB with less than 200 MB of RAM free. A plain HTTP retry
then exposed a non-working IPv6 route. The installer now downloads without
instantiating the model and uses a process-local IPv4 preference; it does not
change Windows network configuration. An unauthenticated Hugging Face warning
is harmless for public models, although an optional `HF_TOKEN` can increase
rate limits. The upstream `torch.jit.script` deprecation warning is also
non-fatal.
