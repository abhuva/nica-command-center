# Gate 6: Aggregate workspace launcher

**Status**: Accepted

**Date**: 2026-10-08

## Boundary

The repository now owns the one-button local workspace entry point without
combining the tools into one server. `start-workspace.cmd` launches a
short-lived PowerShell reconciler hidden. The reconciler starts or retains
independent Homepage, Calendar, Email, VaultGraph, NICA Fava, and TOHU Fava
processes, records their individual outcomes, opens configured views, and then
exits. `stop-workspace.cmd` validates and stops repository-owned services while
leaving Obsidian open.

Homepage is always started because it is the control surface. Settings expose
separate next-start choices for Calendar, Email, VaultGraph, and both finance
services. Module visibility is unchanged and does not implicitly start or stop
a service. Monitoring and Beantime Fava keep their existing Homepage-managed
lifecycle.

Machine-specific paths and ports are stored outside Git in a workspace profile
below `%LOCALAPPDATA%\NICA\CommandCenter\live\launcher`. The profile contains
no credentials. Homepage can update only its normalized local settings through
the bounded `settings.manage` capability. Bookmark and search clicks use the
separate `obsidian.open` capability against the explicitly configured vault;
unrestricted writes remain off.

This implements
[ADR-005](../adr/ADR-005-use-a-repository-owned-workspace-launcher.md).

## Initial configuration and start

Preview and then create the machine-local profile:

```powershell
.\scripts\configure-workspace.ps1 `
  -VaultRoot $env:NICA_VAULT_ROOT `
  -ObsidianVaultName "<vault-name>"
.\scripts\configure-workspace.ps1 `
  -VaultRoot $env:NICA_VAULT_ROOT `
  -ObsidianVaultName "<vault-name>" `
  -Apply
```

Preview and then reconcile the workspace:

```powershell
.\scripts\start-workspace.ps1
.\scripts\start-workspace.ps1 -Apply
```

Repeated startup retains a healthy process only when its manifest, repository,
component, vault authority, state root, port, and API authority all match the
profile. A failure is recorded without preventing unrelated services from
starting. The aggregate status is written to
`launcher/workspace-status.json` below the configured state root.

## Beantime data boundary

Beantime's authoritative ledger remains in Nextcloud. Before the old `Tools`
checkout can be retired, its ledger is copied from
`Tools/data/beantime/zeit.beancount` to the vault-owned location
`1. Vereinsverwaltung/Buchhaltung/Zeiterfassung/zeit.beancount`. The switch
requires Homepage and any active timer to be stopped, verifies SHA-256 before
publishing, updates only machine-local runtime configuration, and retains the
old file.

```powershell
.\scripts\migrate-beantime-ledger.ps1 -VaultRoot $env:NICA_VAULT_ROOT
.\scripts\migrate-beantime-ledger.ps1 -VaultRoot $env:NICA_VAULT_ROOT -Apply
```

The operation is idempotent when the existing destination still matches the
retained source. No ledger content belongs to this repository or its Git
history.

## Rollback

Stop the migrated services before starting the old vault-local launcher:

```powershell
.\scripts\stop-workspace.ps1
```

For Beantime, preview and apply the profile rollback while Homepage and the
timer are stopped:

```powershell
.\scripts\restore-beantime-ledger-profile.ps1 -VaultRoot $env:NICA_VAULT_ROOT
.\scripts\restore-beantime-ledger-profile.ps1 -VaultRoot $env:NICA_VAULT_ROOT -Apply
```

If bookings were appended after cutover, rollback first verifies that the
retained source did not change, saves a verified local recovery copy, and
atomically synchronizes the current destination back to the legacy source
before changing the runtime profile. If both ledgers changed, it blocks rather
than choosing a winner. Neither ledger is deleted.

The old `startup-all.bat` and vault-local tools remain available during Gate 7.
They must not run concurrently with migrated writers.

## Verification

Completed before live cutover:

- PowerShell parsing passes for configuration, aggregate start/stop, finance,
  and ledger migration/rollback scripts.
- Synthetic checks cover plan-only behavior, startup selections, finance
  lifecycle, active-timer rejection, hash-preserving ledger publication,
  post-cutover booking preservation during rollback, and reactivation.
- Homepage API tests verify that `settings.manage` is independent from project
  creation and unrestricted writes.
- Playwright MCP verified the real Settings page at a 375-by-812 viewport with
  synthetic API data: saved startup selections were present in the POST body,
  the success state was visible, there was no horizontal overflow, and no
  console warning or error occurred.

Live cutover verification on 2026-10-08 established:

- the machine-local workspace profile uses the already accepted vault,
  Obsidian vault name, component ports, and finance-ledger paths;
- Homepage was the only accepted service stopped for the ledger switch;
  Calendar, Email, and VaultGraph remained healthy and were retained;
- Beantime source and destination SHA-256 matched after publication, immediate
  profile rollback, and reactivation, with no active timer and no booking;
- aggregate startup reported every selected service healthy, starting Homepage
  and both finance services while retaining Calendar, Email, and VaultGraph;
- a repeated aggregate start retained every healthy process and opened both
  Homepage and Calendar in Obsidian; the launcher now records each view result
  and falls back to the tested Web Viewer API when the CLI `web` command is not
  registered yet;
- all six HTTP services responded successfully and the aggregate status was
  `ok`;
- the live Homepage reported limited-write mode with `settings.manage` enabled
  and unrestricted writes disabled;
- after the first normal-workflow click exposed an over-broad POST guard,
  `obsidian.open` was separated as a bounded capability; a live API replay and
  Playwright MCP click both opened the Calendar bookmark successfully while
  unrestricted writes remained disabled;
- Playwright MCP loaded and saved the real schema-v2 Settings UI with every
  startup default enabled, no horizontal overflow, and no console warning or
  error.

Marc tested the normal workspace and its linked tools after the launcher and
bookmark-address corrections and confirmed on 2026-10-08 that they work. Gate
6 is accepted. Live use now enters Gate 7 observation; the old checkout and
retained Beantime source remain available for recovery until explicit
retirement approval.
