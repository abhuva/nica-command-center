# Gate 4: shadow verification

**Status:** complete for the credential-free shadow scope  
**Date:** 2026-10-06  
**Branch:** `migration/tools-gate-4`

Gate 4 ran the candidate beside the unchanged production checkout. Real-vault
checks were read-only and reported only aggregate comparisons. All mutating
checks used a disposable synthetic vault and isolated state outside the
repository and production vault.

## Safety outcome

- Production launchers, source files, credentials, and runtime state were not
  changed.
- Production Calendar, Homepage, and Email health endpoints remained healthy
  throughout the run. Production VaultGraph was already stopped and was not
  started or changed.
- Every real-vault candidate write endpoint tested through Playwright returned
  `403 NICA_READ_ONLY`.
- A consistent SQLite backup API created the temporary Email shadow database
  while production remained running; it passed SQLite `quick_check`.
- Temporary real-data and synthetic Gate 4 trees were removed after validation.
- External Google, Nextcloud, IMAP, SFTP, and OAuth credentials were neither
  copied nor enabled.

Gate 4 found and removed an unsafe legacy behavior: Obsidian CLI calls could
retry against the active vault when explicit targeting failed. Candidate CLI
reads now require `OBSIDIAN_VAULT_NAME` and never retry without it. Obsidian UI
actions additionally require `NICA_OBSIDIAN_ACTIONS_ENABLED=true`. A negative
project-creation test proved that an enabled action profile without a vault
name fails before creating a directory.

## Capability evidence

| Capability | Read/shadow evidence | Controlled-write evidence |
| --- | --- | --- |
| VaultGraph | Real vault indexed with no scan errors; browser graph rendered. | Synthetic rebuild completed with no graph errors. |
| Homepage | Bookmark root aggregate matched production; candidate links and badge rendered. | Synthetic project file and frontmatter were created with Obsidian actions disabled. |
| Website monitoring | Monitor ran with its own state and retained history across restart. | Only replaceable candidate monitoring state was written. |
| Calendar | Candidate bundle matched the production generated bundle byte-for-byte. | Synthetic note create, date update, fallback rebuild, and 2030 UI rendering passed. |
| Email | Consistent snapshot aggregates matched production for messages and rules. | Synthetic store/deduplicate/tag/rule/export smoke passed; an empty HTTP export remained bounded. |
| Beantime | Synthetic ledger metadata loaded from candidate state. | Timer start/stop appended one synthetic transaction and cleared timer state. |

The existing Email smoke exercises message ingestion without a network account.
An actual IMAP fetch is intentionally deferred because no synthetic IMAP
adapter exists and production credentials were out of scope.

## Operability and browser verification

- Read-only shadow startup completed in about 8.5 seconds after a full stop.
- Candidate shutdown completed in about 1.0 to 1.4 seconds in measured runs,
  well inside the five-minute rollback objective.
- Stopping candidate VaultGraph left candidate Calendar, Homepage, and Email
  healthy; production services also remained healthy.
- Restart preserved the Email snapshot, Calendar output match, bookmark
  aggregate, and monitoring history.
- The installed Playwright MCP verified all four candidate UIs at 375 px width
  in both read-only and synthetic read-write profiles. Candidate labels,
  primary UI surfaces, health modes, controlled interactions, and absence of
  horizontal overflow were checked.
- Expected console noise was limited to missing local favicons and deliberately
  exercised error responses (`403`, `502`, and `422`).

## Rollback and cleanup

The rehearsed rollback is:

```powershell
.\scripts\stop-candidate.ps1 -StateRoot "<candidate-state-root>"
```

Production already remains on ports 4173, 4174, and 4176, so Gate 4 rollback
does not require restarting or repointing the daily tools. Candidate ports
4273 through 4276 were confirmed closed after shutdown. Disposable write
artifacts existed only below the synthetic Gate 4 tree; neither known test
artifact existed in the live vault.

## Gate 5 prerequisites

Before a capability cutover:

1. Configure the exact Obsidian vault name where CLI integration is needed.
2. Transfer only that capability's required credentials into an agreed local
   secret mechanism.
3. Verify Google/CalDAV/IMAP behavior in a bounded maintenance window before
   enabling the corresponding live writer.
4. Keep the current production component running until its individual Gate 5
   acceptance and rollback checks pass.
