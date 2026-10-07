# Gate 5: Calendar vault-event creation cutover

**Status:** technical candidate verified; live cutover not started

**Date:** 2026-10-07

**Branch:** `migration/calendar-vault-write-cutover`

This cutover adds one controlled write capability to the accepted migrated
Calendar on port `4273`: creation of Markdown event notes in the configured
vault inbox. The accepted read-only Calendar remains the live workflow until a
separate cutover apply, and legacy Calendar `4173` remains the rollback.

## Boundaries

- The vault remains authoritative for Markdown event notes and Calendar inbox
  conventions.
- `NICA_CALENDAR_VAULT_CREATE_ENABLED=true` enables only
  `calendar.vault-event.create`; `NICA_WRITE_ENABLED` remains false.
- Google Calendar, Nextcloud CalDAV, OAuth, event update/drag/resize, rebuild,
  Obsidian actions, and public publishing remain disabled.
- The accepted filtered read profile is reused. No OAuth credential, remote
  create target, token, or publishing credential is added.
- Audit records contain outcome, a plan prefix, all-day status, date, and error
  code. They exclude event titles, note paths, and note content.

## Plan and apply behavior

The first UI action requests a non-mutating server plan. The server validates
title length and control characters, date formats and ordering, the configured
inbox boundary, and the exact collision-free note path. The UI displays that
path and enables Create only for the unchanged plan.

Apply recomputes the plan and rejects missing, stale, changed, or collided
plans. The complete note is written to a unique non-Markdown staging file in
the inbox and atomically renamed to the planned `.md` target. Failure removes
only that exact staging file or newly published target.

## Start and rollback

Preview the narrow runtime without changing the running reader:

```powershell
.\scripts\start-calendar-vault-write.ps1 -VaultRoot "C:\path\to\vault" -ObsidianVaultName "vault-name"
```

For the controlled cutover, stop only migrated Calendar `4273` and apply the
narrow profile:

```powershell
.\scripts\stop-calendar-read.ps1
.\scripts\start-calendar-vault-write.ps1 -VaultRoot "C:\path\to\vault" -ObsidianVaultName "vault-name" -Apply
```

Rollback restores the accepted read-only migrated Calendar without changing
legacy `4173` or vault content:

```powershell
.\scripts\stop-calendar-read.ps1
.\scripts\start-calendar-read.ps1 -VaultRoot "C:\path\to\vault" -ObsidianVaultName "vault-name" -Apply
```

## Technical verification evidence

- The synthetic API workflow verified health capabilities, token enforcement,
  invalid input, plan-only behavior, changed and stale plan rejection, exact
  frontmatter, atomic publication, no staging residue, and redacted audit data.
- Every unrelated POST route and Google OAuth start remained HTTP 403 while
  vault creation was enabled.
- The launcher started in `limited-write` mode against the synthetic vault and
  local CalDAV fixture, while Google/CalDAV write configuration remained absent.
- Playwright MCP completed preview and apply through the Calendar UI, verified
  plan invalidation after a title change, displayed the created event, found no
  horizontal overflow at 375 px, and found no browser warnings or errors.
- The synthetic event and isolated runtime state were removed. The launcher
  rollback restored `read-only` mode and returned the plan route to HTTP 403.
- Live migrated Calendar `4273` remained read-only and healthy throughout;
  legacy `4173` remained available.

## Acceptance checklist

- [x] Synthetic API and UI creation succeed without live vault data.
- [x] Unrelated local and remote mutations remain disabled.
- [x] Launcher start, stop, restart, and read-only rollback are rehearsed.
- [x] Failure paths leave no staging or duplicate final note.
- [x] Browser-level responsive and console checks pass with Playwright MCP.
- [ ] Preview the live runtime authority and capability set without restarting.
- [ ] Apply the narrow profile during a controlled cutover.
- [ ] Marc creates one needed event and confirms the normal workflow.
