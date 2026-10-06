# Gate 3: parallel candidate runtime

**Status:** complete
**Branch:** `migration/tools-gate-3`

Gate 3 makes the imported tools runnable outside the vault without changing or
stopping the production checkout.

## Safety contract

- The vault is selected only through the absolute `NICA_VAULT_ROOT` value.
- Replaceable state is written only below absolute `NICA_STATE_ROOT`, which
  must be outside the vault tree.
- The candidate defaults to read-only action endpoints.
- Candidate ports are 4273-4276; the existing production ports remain
  4173-4176. Candidate Fava uses 4464 instead of 3464.
- The existing vault checkout and its launchers are not changed.
- Automated checks use `tests/fixtures/vault`, never live society data.

The accepted boundary is documented in
[ADR-002](../adr/ADR-002-explicit-vault-and-local-state-roots.md).

## Reproducible checks

```powershell
npm.cmd run check:runtime
python .\Email\email_tool.py smoke

$env:NICA_VAULT_ROOT = (Resolve-Path .\tests\fixtures\vault).Path
$env:NICA_STATE_ROOT = Join-Path $env:TEMP "nica-command-center-gate3"
$env:NICA_WRITE_ENABLED = "false"
$env:ALLOW_MARKDOWN_FALLBACK = "true"
npm.cmd run doctor
node .\Calendar\build-events.mjs
node .\VaultGraph\build-graph.mjs
```

Preview a real-vault candidate plan without starting anything:

```powershell
.\scripts\start-candidate.ps1 -VaultRoot "C:\path\to\vault"
```

Only after reviewing that output, start the isolated candidate:

```powershell
.\scripts\start-candidate.ps1 -VaultRoot "C:\path\to\vault" -Apply
```

The `-WriteEnabled` switch is deliberately separate and is not part of normal
Gate 3 verification. Stop only candidate processes recorded by the launcher:

```powershell
.\scripts\stop-candidate.ps1
```

## Verification evidence

- Missing, relative, nested, and valid root configurations passed the runtime
  failure smoke test.
- Root lint, Python compilation, Email smoke, Calendar build/smoke, and
  VaultGraph build/smoke passed with synthetic inputs.
- The root npm audit was reduced from three transitive findings to zero through
  patched lockfile-compatible resolutions.
- All four health endpoints reported the synthetic vault as authority, their
  own local-state directories, and `writesEnabled: false`.
- POST requests to Homepage, Calendar, VaultGraph, and Email returned HTTP 403
  in the read-only profile.
- The candidate launcher handled a startup failure by stopping every process
  it had started; the corrected launcher then started and health-checked all
  four components and stopped them cleanly.
- Failure isolation was verified by stopping VaultGraph: Calendar, Homepage,
  and Email remained healthy.
- Browser-level verification used the installed Playwright MCP. Homepage,
  Calendar, VaultGraph, and Email rendered at candidate ports; embedded links
  stayed on candidate ports; Calendar loaded the synthetic event; write-action
  controls displayed the read-only failure; and the checked narrow layouts had
  no horizontal overflow.
- Production listeners on ports 4173, 4174, and 4176 remained present after
  candidate testing. No production launcher or source-vault file was changed.

Expected browser-console noise is limited to absent favicon requests and the
deliberately exercised HTTP 403 responses.
