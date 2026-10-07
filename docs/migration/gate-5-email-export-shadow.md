# Gate 5: Email bounded-export shadow

**Status:** synthetic and browser verification complete; live activation pending

**Date:** 2026-10-07

## Scope

Extend the accepted Email candidate on `4276` with bounded Markdown export. The
profile retains Count/Fetch, classification, and OAuth management and adds
exactly `vault.export`. The accepted OAuth profile remains the candidate
rollback target, and legacy Email `4176` remains available as the warm fallback.

The export workflow has two explicit steps. Preview classifies the current
selection and changes neither the vault nor the Email database. Apply accepts
only a current one-use plan token and revalidates the database rows and target
files before publishing anything.

## Safety boundaries

- The global Email write switch remains false. The exact capability allowlist
  is `mail.count`, `mail.fetch`, `message.tag`, `oauth.manage`, `rules.apply`,
  `rules.manage`, and `vault.export`.
- A preview reports only aggregate `create`, `unchanged`, and `conflict` counts.
  It does not create the export directory or update export metadata.
- A matching existing Markdown file is adopted as `unchanged` without being
  rewritten. A different file or non-file at the target path is a conflict and
  prevents apply.
- The established flat Email archive uses an older path and frontmatter schema.
  Preview identifies those notes through the account-folder slug and filename
  timestamp, reading the bounded frontmatter `uid` only when a timestamp is
  ambiguous. It reports them separately as `legacyExisting` and never rewrites
  them. Multiple legacy notes for one message are a blocking conflict. Only
  included messages without an established projection use the new
  collision-resistant account/year/month path.
- Plan tokens are random, one-use, process-local, and expire after five minutes.
  Apply recomputes the selection, rendered content, and target hashes before it
  accepts the plan.
- New notes are written to exclusive staging files, flushed to disk, and
  published with a hard link that cannot replace a concurrently created target.
  Database export metadata is committed only after every target is present with
  the planned content hash.
- A failed batch rolls back database state, removes only newly published files
  that still match the staged content, removes staging files, and cleans up
  newly created empty directories. A file changed during rollback is preserved
  and reported as a rollback conflict.
- The bounded server rejects the legacy direct `/api/export` route. The UI uses
  `/api/export/plan` followed by a separate `/api/export/apply` action.
- Tests use only isolated synthetic messages and a temporary vault.

## Commands

Preview the runtime transition without changing files or processes:

```powershell
.\scripts\start-email-export-shadow.ps1 -VaultRoot "C:\path\to\vault"
```

After reviewing that plan, stop only migrated Email `4276` and activate the
bounded profile:

```powershell
.\scripts\stop-email-read.ps1
.\scripts\start-email-export-shadow.ps1 -VaultRoot "C:\path\to\vault" -Apply
```

Activation enables the capability but does not export a message. Use **Preview
Export** in the Email UI to inspect aggregate counts, then use **Apply Export**
as a separate action only after the preview is acceptable.

## Rollback

Stop the export profile and restart the accepted OAuth profile without
refreshing the candidate database, account profile, or token backups:

```powershell
.\scripts\stop-email-read.ps1
.\scripts\start-email-oauth-shadow.ps1 -VaultRoot "C:\path\to\vault" -Apply
```

This immediately removes vault-export authority while retaining the accepted
Email state. Existing exported Markdown files are projections and are not
deleted automatically during profile rollback.

## Verification evidence

- `npm run check:email-export-shadow` passed with synthetic preview/apply,
  read-only preview, one-use tokens, unchanged-file adoption, differing-file
  conflict refusal, established-archive adoption without rewrite or duplicate,
  ambiguous-archive conflict refusal, stale-database rejection, atomic
  publication failure, filesystem and database rollback, exact capability
  health, direct-route rejection, launcher plan/apply/stop, and rollback to
  OAuth.
- The read, fetch, classification, OAuth, export, and component smoke suites all
  passed together after the launcher extension. ESLint, Python compilation,
  PowerShell parsing, and `git diff --check` also passed.
- Playwright MCP verified the revised synthetic UI on `4476`: preview reported
  one established-archive note and zero new, unchanged, or conflicting notes;
  apply required a separate click and reported the archive adoption without a
  file rewrite; the final success status remained visible after refresh; a
  375-by-812 viewport had no horizontal overflow; and the console had no
  warnings or errors.
- The live candidate remained on the accepted OAuth profile throughout
  implementation and synthetic verification. No live vault export occurred.
- The live launcher plan retained the existing candidate database and profile,
  six configured accounts, one OAuth token, and its existing immutable recovery
  copy. It proposed the exact export capability set and no snapshot, profile,
  credential, token, process, or legacy change. Candidate `4276` and legacy
  `4176` were healthy; candidate health still reported `vault.export` false.
- The pre-activation vault baseline contained 11,751 Markdown projections with
  latest write time `2026-06-25T11:25:00Z`.
- The first live activation enabled only the reviewed capability set and kept
  legacy `4176` healthy. Its read-only preview classified all 4,641 included
  messages as new because the established 11,751-note archive uses the older
  flat layout and frontmatter schema. Apply was not used. Candidate `4276` was
  immediately rolled back to the accepted OAuth profile; the vault count and
  latest-write timestamp remained identical. Aggregate reconciliation then
  mapped 11,695 existing notes to candidate messages, including 4,125 included
  messages, through account slug, timestamp, and bounded UID checks without
  exposing message content.
- The first revised full-vault preview opened every legacy note and exceeded a
  45-second client timeout. Apply was not used, and `4276` was rolled back again
  with the vault baseline unchanged. Filename indexing now resolves 4,074 of
  the included archive notes without opening them and reads bounded UID
  frontmatter only for 51 ambiguous-timestamp messages. A read-only local run
  produced the expected aggregate result in 28.98 seconds: 516 new, 4,125
  existing-archive, zero unchanged, and zero conflicts.

## Live acceptance checklist

- [x] Review a live launcher plan that retains the accepted candidate database,
  account profile, OAuth tokens, and token recovery copies.
- [ ] Confirm migrated `4276` and legacy `4176` are healthy before activation.
- [ ] Activate `vault.export` on `4276` without refreshing accepted state.
- [ ] Confirm exact health capabilities and direct-export rejection.
- [ ] Run a live export preview and review aggregate create, unchanged, and
  legacy-existing/conflict counts without logging message names or content.
- [ ] Apply an explicitly accepted bounded export and verify its projection and
  database metadata.
- [ ] Rehearse rollback to the accepted OAuth profile.
- [ ] Marc confirms the normal Email export workflow is usable.
