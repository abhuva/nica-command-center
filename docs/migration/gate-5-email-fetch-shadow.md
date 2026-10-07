# Gate 5: Email bounded-fetch shadow

**Status:** live bounded-fetch shadow active; awaiting normal-workflow acceptance

**Date:** 2026-10-07

**Branch:** `migration/email-fetch-shadow`

This slice extends the accepted Email read-only shadow without changing which
installation is authoritative. Candidate `4276` may count and fetch mail into
its isolated SQLite snapshot. Legacy Email `4176` remains the daily production
workflow and the immediate fallback.

## Authority and safety boundary

- IMAP mailboxes are selected with `readonly=True` and fetched with
  `BODY.PEEK[]`; the candidate does not set IMAP processing flags.
- Candidate writes are limited to its isolated SQLite snapshot, sync metadata,
  and a candidate OAuth-token refresh when required for authentication.
- `NICA_WRITE_ENABLED` remains false.
- `NICA_EMAIL_CAPABILITIES` contains only `mail.count,mail.fetch`.
- OAuth setup, classification, rule changes, rule application, manual tags, and
  vault export remain blocked with HTTP 403.
- Configuration, password environment files, OAuth tokens, database snapshots,
  logs, and manifests remain local state outside the vault and repository.
- No mail payload is logged, committed, or used as an automated browser
  artifact.

## Plan and apply

The launcher is plan-only unless `-Apply` is present. The plan reports only
profile counts and operational boundaries, not account identifiers or secret
values.

```powershell
# Preview the bounded profile and consistent snapshot refresh
.\scripts\start-email-fetch-shadow.ps1 `
  -VaultRoot "C:\path\to\vault" `
  -PrepareFetchProfile `
  -RefreshSnapshot

# After review, prepare isolated local state and start the candidate
.\scripts\start-email-fetch-shadow.ps1 `
  -VaultRoot "C:\path\to\vault" `
  -PrepareFetchProfile `
  -RefreshSnapshot `
  -Apply
```

The launcher copies only the local Email configuration, existing environment
file, and OAuth-token paths explicitly referenced by configured OAuth accounts.
Token paths must be relative and contained within both source and destination
Email state directories. Symbolic links and reparse-point sources are rejected.

Stop the candidate while retaining its isolated snapshot and profile:

```powershell
.\scripts\stop-email-read.ps1
```

Restart the accepted read-only shadow with `start-email-read.ps1`. Legacy Email
`4176` remains available throughout.

## Verification evidence

- Synthetic health reports `limited-write` with only `mail.count` and
  `mail.fetch` enabled.
- All allowed count/fetch routes pass the capability gate; all other POST
  routes return HTTP 403 with the denied capability.
- Unknown capability names fail startup.
- Database and OAuth-token paths cannot escape isolated local state; the export
  directory cannot escape the configured vault root.
- The synthetic launcher is plan-only by default, copies only its fixture
  profile, creates a consistent snapshot, starts successfully, and stops while
  retaining local state.
- The live plan found six configured accounts, one credential environment file,
  and one referenced OAuth token without printing identifiers or values. It
  copied nothing, changed no process, and left legacy `4176` and read-only
  candidate `4276` healthy.
- Playwright MCP verified the limited-write badge and status, enabled only the
  count/fetch controls, kept OAuth, classification, rule, tag, and export
  controls disabled, and completed synthetic Count All and Fetch New All
  actions. The 375 px layout had no horizontal overflow, and the browser
  console contained no warnings or errors.
- The live apply copied the six-account profile, one credential environment
  file, and one referenced OAuth token into isolated local state; refreshed the
  consistent SQLite snapshot; and started `4276` in `limited-write` mode while
  legacy `4176` remained healthy.
- Live Count All authenticated all six accounts with zero account failures.
  Fetch New All used a five-message-per-account limit and stored 30 messages in
  the isolated candidate database without logging payloads.
- The vault Email projection remained untouched, and `vault.export` stayed
  disabled. OAuth setup, classification, rules, and tags also remained blocked.
- Rollback restored the accepted read-only shadow while legacy `4176` stayed
  healthy. The bounded-fetch profile was then restored without refreshing away
  its candidate state.

## Acceptance checklist

- [x] Add server-enforced operation-specific Email capability gates.
- [x] Keep the unrestricted compatibility switch disabled in the launcher.
- [x] Restrict IMAP access to read-only mailbox operations.
- [x] Keep candidate database and token paths inside isolated local state.
- [x] Pass synthetic API, failure-path, launcher, snapshot, and stop checks.
- [x] Verify enabled and disabled UI controls with Playwright MCP.
- [x] Review the plan against the live profile without copying credentials or
  changing a process.
- [x] Stop only the accepted read shadow and apply the bounded fetch profile.
- [x] Run a bounded count/fetch without recording mail payloads.
- [x] Confirm legacy `4176` remained healthy and the vault remained unchanged.
- [x] Rehearse rollback to the accepted read-only shadow.
- [ ] Marc confirms the bounded fetch workflow is usable.
