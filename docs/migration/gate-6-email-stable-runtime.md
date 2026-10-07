# Gate 6: Email stable runtime

**Status**: Accepted

**Date**: 2026-10-07

## Boundary

The normal Email entry point is now `scripts/start-email.ps1`, with
`scripts/stop-email.ps1` as its matching stop command. The stable profile runs
on `127.0.0.1:4276` and enables only the already accepted bounded capabilities:

- `mail.count`
- `mail.fetch`
- `message.tag`
- `oauth.manage`
- `rules.apply`
- `rules.manage`
- `vault.export`

The global unrestricted-write switch remains false. The launcher points the
optional theme bridge at migrated Homepage `4274`.

## Database decision

The stable switch reused the current local database without copying, replacing,
or resetting it. Aggregate candidate, included, excluded, exported, and total
counts were identical before and after the process restart.

This does not make the database authoritative. Under
[ADR-004](../adr/ADR-004-treat-email-database-as-rebuildable-local-state.md), a
new state root can use `-InitializeFreshDatabase`; that path refuses to
overwrite an existing database and does not require a legacy database. The
recorded 515-note export batch was not applied.

## Rollback

The previous accepted migrated profile uses the same local state and remains
available without a database restore:

```powershell
.\scripts\stop-email.ps1
.\scripts\start-email-export-shadow.ps1 `
  -VaultRoot $env:NICA_VAULT_ROOT `
  -Apply
```

The former vault-local service on `4176` was unavailable during this switch,
but its source and database were not deleted or modified.

## Verification

- The stable launcher plan succeeded against the existing local state without
  changing the running process.
- The full Email smoke, read, fetch/fresh-start, classification, OAuth, and
  export suites passed.
- Synthetic fresh initialization created an empty schema without a legacy
  database, refused overwrite, restarted normally, and shut down cleanly.
- Live `4276` reported component `email`, limited-write mode, every expected
  bounded capability, and unrestricted writes disabled.
- The Homepage theme bridge was available through `4274`.
- Playwright MCP verified the live UI with six configured accounts at a
  375-by-812 viewport, no horizontal overflow, a disabled Apply Export action
  without a plan, and zero console warnings or errors. No message identifiers,
  subjects, addresses, or bodies were recorded.
- Marc confirmed the normal Dashboard, Account, and Rules interface on
  `4276` works after the switch.
