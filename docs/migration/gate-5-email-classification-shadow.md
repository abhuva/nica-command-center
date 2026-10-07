# Gate 5: Email bounded-classification shadow

**Status:** synthetic and browser verification complete; live activation not started

**Date:** 2026-10-07

## Scope

Extend the accepted Email candidate on `4276` with local classification while
retaining its bounded Count/Fetch capabilities. The classification profile
enables exactly:

- `mail.count`
- `mail.fetch`
- `message.tag`
- `rules.apply`
- `rules.manage`

OAuth management and `vault.export` remain disabled. Classification changes
only the isolated candidate SQLite database below the configured runtime-state
root. It does not write Markdown projections into the vault.

Legacy Email `4176` remains available for the established workflow and as the
immediate fallback. The accepted fetch-only profile remains the candidate
rollback target.

## Safety boundaries

- The global Email write switch remains false.
- The server enforces every enabled operation through the capability allowlist;
  disabled routes return HTTP 403 before request payload parsing.
- The classification launcher reuses the accepted candidate database and
  profile by default. It does not refresh either from legacy state unless those
  actions are explicitly requested.
- `-BackupCandidate` creates a consistent SQLite rollback snapshot at
  `email/backups/email-before-classification.db` below the runtime-state root
  before the classification process starts.
- The launcher refuses a requested backup when the candidate database does not
  already exist.
- No test or launcher writes Email content into the vault.

## Commands

Preview the live transition without changing files or processes:

```powershell
.\scripts\start-email-classification-shadow.ps1 -VaultRoot "C:\path\to\vault" -BackupCandidate
```

After reviewing the plan, stop only the migrated Email candidate and activate
classification with its rollback snapshot:

```powershell
.\scripts\stop-email-read.ps1
.\scripts\start-email-classification-shadow.ps1 -VaultRoot "C:\path\to\vault" -BackupCandidate -Apply
```

## Rollback

Stop classification and restart the accepted fetch-only profile without
refreshing its profile or database:

```powershell
.\scripts\stop-email-read.ps1
.\scripts\start-email-fetch-shadow.ps1 -VaultRoot "C:\path\to\vault" -Apply
```

This immediately removes rule, tag, and classification authority while
retaining candidate state. If classification corrupts or unexpectedly changes
candidate state, stop the service, preserve the failed database for diagnosis,
restore `email/backups/email-before-classification.db` to the candidate
`email.db` with `Email/snapshot_db.py`, and start the fetch-only profile.

## Verification evidence

- `npm run check:email-classification-shadow` passed with synthetic messages,
  rule creation/application/deletion, manual tagging, exact capability health,
  disabled OAuth/export routes, launcher plan/apply/stop, a consistent rollback
  snapshot, and rollback to the fetch-only profile.
- `npm run check:email-fetch-shadow` still passed after the launcher extension.
- Playwright MCP verified the synthetic candidate UI on `4476`: the page showed
  `Ready · bounded Email classification`; Count, Fetch, rule management, and
  Apply Rules were enabled; OAuth and Export were disabled; a synthetic global
  rule could be saved and applied; all observed API calls returned HTTP 200;
  the console had no warnings or errors; and a 375-by-812 viewport had no
  horizontal overflow.
- The live candidate remained on the accepted fetch-only profile throughout
  implementation and synthetic verification.

## Acceptance checklist

- [x] Capability gates are enforced server-side.
- [x] Classification mutations are confined to isolated candidate SQLite state.
- [x] OAuth management and vault export remain blocked.
- [x] Plan mode changes no file or process.
- [x] A consistent pre-classification rollback snapshot is available.
- [x] Synthetic classification and fetch-profile regression checks pass.
- [x] Playwright MCP verifies the bounded UI and rule workflow.
- [ ] Review the live plan and current candidate-state baseline.
- [ ] Activate the profile on `4276` without refreshing accepted candidate state.
- [ ] Verify a bounded live classification workflow without logging payloads.
- [ ] Rehearse rollback to the accepted fetch-only profile.
- [ ] Marc confirms the normal classification workflow is usable.
