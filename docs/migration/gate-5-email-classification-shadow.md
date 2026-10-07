# Gate 5: Email bounded-classification shadow

**Status:** live bounded-classification shadow active; awaiting normal-workflow acceptance

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

## Live activation evidence

- The reviewed plan retained the accepted candidate database and profile. It
  proposed no legacy snapshot refresh and no credential copy.
- Before activation, `4276` was healthy in the accepted fetch-only profile with
  12,806 messages, 236 rules, and 11 tags. Legacy `4176` was healthy.
- The vault projection baseline contained 11,757 files and had a latest write
  time of `2026-06-25T11:25:00Z`.
- Stopping fetch-only `4276`, creating the rollback snapshot, and starting the
  classification profile completed successfully. The rollback snapshot and a
  separate verification both reported SQLite `quick_check: ok`.
- Live health reported exactly Count, Fetch, message tagging, rule application,
  and rule management. OAuth management and vault export returned HTTP 403.
- A temporary disabled synthetic rule was created and removed, and a no-op
  message-tag request succeeded without logging a message identifier or
  content.
- Applying the 236 existing rules completed with 8,362 aggregate matches and
  updates. The candidate retained 12,806 messages, 236 rules, and 11 tags.
- Rollback to the accepted fetch-only profile disabled classification while
  preserving the aggregate message state: 5,732 candidate, 4,645 included,
  2,429 excluded, and zero exported. Classification was then restored without
  refreshing candidate state or overwriting the recovery snapshot.
- Live Playwright MCP verification showed the bounded-classification status;
  Count, Fetch, Apply Rules, and rule management were enabled; OAuth and Export
  were disabled; observed API calls returned HTTP 200; the console had no
  warnings or errors; and the page had no horizontal overflow.
- Legacy `4176` remained healthy. The vault projection file count and latest
  write time remained identical to the baseline.
- One rapid startup health request disconnected before the response completed,
  producing a client-abort traceback without message content. Subsequent health,
  API, and browser checks were clean.

## Acceptance checklist

- [x] Capability gates are enforced server-side.
- [x] Classification mutations are confined to isolated candidate SQLite state.
- [x] OAuth management and vault export remain blocked.
- [x] Plan mode changes no file or process.
- [x] A consistent pre-classification rollback snapshot is available.
- [x] Synthetic classification and fetch-profile regression checks pass.
- [x] Playwright MCP verifies the bounded UI and rule workflow.
- [x] Review the live plan and current candidate-state baseline.
- [x] Activate the profile on `4276` without refreshing accepted candidate state.
- [x] Verify a bounded live classification workflow without logging payloads.
- [x] Rehearse rollback to the accepted fetch-only profile.
- [ ] Marc confirms the normal classification workflow is usable.
