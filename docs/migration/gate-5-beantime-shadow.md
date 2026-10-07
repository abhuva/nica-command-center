# Gate 5 Beantime synthetic shadow

**Status**: Accepted synthetic shadow; live tool cutover recorded separately

**Date**: 2026-10-07

## Scope

This slice verifies the migrated Beantime timer and managed Fava integration
without reading or writing a production ledger. The launcher creates a dedicated
synthetic vault, ledger, and timer-state tree below the configured sandbox.
The accepted Homepage on `4274`, legacy Homepage on `4174`, on-demand Beantime
Fava on `3464`, and finance Fava services on `4998` and `4999` are unchanged.

The shadow defaults to metadata reads only. These additional switches enable
separate server-enforced capabilities:

| Launcher switch | Capability | Authority |
| --- | --- | --- |
| Always present | `beantime.read` | Read the explicitly provisioned synthetic ledger and timer state |
| `-EnableTimer` | `beantime.timer` | Create or retain isolated running-timer state |
| `-EnableAppend` | `beantime.append` | Finalize a timer into the synthetic ledger; requires timer capability |
| `-EnableFava` | `beantime.fava` | Start managed Fava on the separate shadow port |

`NICA_WRITE_ENABLED` remains false. Unknown capability names fail startup, and
the server checks the exact capability before parsing a Beantime action request.
The metadata route no longer creates a missing ledger. Provisioning belongs to
the launcher so a read cannot silently establish a new authority.

## Plan and start

Review the default synthetic paths and ports without changing anything:

```powershell
./scripts/start-beantime-shadow.ps1 -EnableTimer -EnableAppend -EnableFava
```

Start the isolated shadow after reviewing that plan:

```powershell
./scripts/start-beantime-shadow.ps1 -EnableTimer -EnableAppend -EnableFava -Apply
```

The Homepage is then available at `http://127.0.0.1:4374/home.html`. Fava is
started on demand at `http://127.0.0.1:4464/`. Obsidian actions remain disabled,
so the synthetic test cannot open or act on the daily vault.

## Stop and rollback

```powershell
./scripts/stop-beantime-shadow.ps1
```

The stop command validates the process manifest, stops only the recorded server
and its managed Fava child, verifies both shadow ports are free, and retains the
synthetic ledger and timer state. Production services do not need to be
restarted because this slice never changes them.

## Automated verification

```powershell
npm run check:beantime-shadow
npm run lint
```

The smoke check verifies:

- unknown capabilities fail before the server listens;
- disabled routes return `403` and do not create a ledger;
- metadata reads fail cleanly when the ledger is absent and never provision it;
- timer-only authority cannot append or clear the running state;
- bounded timer plus append authority records only into the synthetic ledger;
- unrelated Homepage writes and managed Fava launch remain disabled unless
  separately authorized.

## Verification result

On 2026-10-07 the isolated `4374` Homepage passed a Playwright MCP workflow:

- the UI loaded only the synthetic Beantime module and exposed the expected
  start, stop, append, and Fava controls;
- a timer was started and stopped, and its transaction appeared only in the
  synthetic ledger;
- managed Fava `1.30.12` started on `4464` without invoking an Obsidian action;
- Fava reported no ledger errors and its Journal displayed the synthetic
  transaction with start/end metadata;
- stop/restart freed both shadow ports, retained the synthetic transaction, and
  restarted without a running timer;
- legacy Homepage `4174`, accepted Homepage `4274`, NICA Fava `4998`, and TOHU
  Fava `4999` continued returning HTTP `200`.

Browser verification initially found that the inherited synthetic template used
`Zeit:` and `Projekte:` roots without declaring their Beancount account types.
The tracked template now declares those roots, passes `bean-check`, and loads in
Fava without errors. The earlier synthetic test ledger was retained locally as a
recovery copy; no production file was involved.

## Acceptance

Marc confirmed the synthetic start, stop, append, and managed-Fava workflow on
2026-10-07. This accepts the isolated shadow only. The legacy workflow remains
unchanged until a separately approved live-ledger transfer and Beantime cutover
have their own rollback plan.

No production ledger path or content belongs in this record. The later tool
cutover retains the ledger in Nextcloud and is recorded in [Gate 5 Beantime tool
cutover](gate-5-beantime-tool-cutover.md).
