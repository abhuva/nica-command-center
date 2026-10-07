# Gate 5 Beantime tool cutover

**Status**: Technical cutover complete; normal-workflow confirmation pending

**Date**: 2026-10-07

## Boundary

This cutover moves only the Beantime software runtime into the command-centre
checkout. The authoritative ledger remains unchanged in the Nextcloud vault at
`Tools/data/beantime/zeit.beancount`. No ledger data was copied, imported,
converted, moved into this repository, or moved into local application state.

The migrated server receives the ledger location through the vault-relative
`NICA_BEANTIME_LEDGER_PATH` setting. Absolute paths, lexical traversal, missing
files, directories, and paths that canonically resolve outside
`NICA_VAULT_ROOT` fail startup. The API and health response report `vault` as
the ledger authority without exposing a machine-specific absolute path.

Running-timer state is transient local state below `NICA_STATE_ROOT`; no legacy
timer was active at cutover. Finalized transactions are appended directly to
the existing Nextcloud ledger.

## Active profile

Homepage `4274` now uses `homepage-project-beantime` with only these bounded
write capabilities:

- `project.create`
- `beantime.read`
- `beantime.timer`
- `beantime.append`
- `beantime.fava`

Global writes remain disabled. Legacy Homepage `4174` is stopped, preventing a
second Beantime writer. Managed Fava remains on its established on-demand port
`3464`. Finance Fava services `4998` and `4999` are separate and unchanged.

## Start and restart

The first preparation is plan-only without `-Apply`:

```powershell
./scripts/start-homepage.ps1 `
  -VaultRoot $env:NICA_VAULT_ROOT `
  -ObsidianVaultName "<vault-name>" `
  -PrepareBeantimeProfile
```

After review, stop the existing migrated Homepage and apply the profile:

```powershell
./scripts/stop-homepage.ps1 -Confirm:$false
./scripts/start-homepage.ps1 `
  -VaultRoot $env:NICA_VAULT_ROOT `
  -ObsidianVaultName "<vault-name>" `
  -PrepareBeantimeProfile `
  -Apply
```

Subsequent restarts omit `-PrepareBeantimeProfile`; the untracked runtime
profile retains the vault-relative ledger pointer.

## Rollback

Rollback is a profile change, not a data restore. It refuses to proceed while a
migrated timer is active.

```powershell
./scripts/stop-homepage.ps1 -Confirm:$false
./scripts/restore-homepage-project-profile.ps1 -Apply
./scripts/start-homepage.ps1 `
  -VaultRoot $env:NICA_VAULT_ROOT `
  -ObsidianVaultName "<vault-name>" `
  -Apply
```

This returns `4274` to the accepted project-creation profile and does not modify
the Nextcloud ledger. If legacy Beantime itself is ever used as a fallback, the
migrated Homepage and managed Fava must first be stopped; both implementations
must never write the ledger concurrently.

## Verification

Technical verification on 2026-10-07 established:

- the existing Nextcloud ledger passes `bean-check`;
- legacy Homepage `4174` was already stopped and no legacy timer state existed;
- the ledger SHA-256 was identical before and after profile preparation and
  migrated server startup;
- `4274` reports the expected bounded capabilities and `vault` ledger authority;
- browser verification through Playwright MCP loaded Beantime with eight
  bookable accounts and four person accounts without exposing their values;
- Start and Show were enabled, Stop was disabled because no timer was active,
  and the UI displayed the vault-relative ledger path;
- managed Fava opened on `3464`, reported no ledger errors, and produced no
  browser console errors;
- an ordinary stop and restart closed managed Fava, restored Homepage on
  `4274`, and left the ledger hash unchanged;
- synthetic tests cover lexical and canonical path escapes, separation of
  vault ledger writes from local timer state, and rollback rejection while a
  timer is active.

No live timer was started and no transaction was appended during technical
cutover. Marc's normal-workflow confirmation remains the acceptance criterion.
