# Gate 7: Observation and legacy-checkout retirement

**Status**: Observation in progress; initial read-only retirement audit complete

**Observation started**: 2026-10-08

## Boundary

Gate 7 proves that the repository-owned workspace can remain the daily
installation before the former vault-local `Tools` checkout is retired. The
Nextcloud vault remains authoritative for organisational data. This gate does
not migrate vault data, delete local state, or silently transfer credentials.

The first retirement audit was read-only. It did not stop or start a service,
change a launcher, modify the vault, copy a credential, rename the old
checkout, or delete recovery material.

## Initial audit evidence

Observed on 2026-10-08:

- the machine-local workspace profile names this repository, not the legacy
  checkout;
- all six process manifests belong to this repository, their processes are
  running, and their configured ports are listening;
- Homepage, Calendar, VaultGraph, Email, NICA Fava, and TOHU Fava each returned
  HTTP 200 during the audit;
- no inspected service command line references the legacy checkout;
- the legacy Calendar, Homepage, and Email ports (`4173`, `4174`, and `4176`)
  have no listeners; port `4175` is owned by the migrated VaultGraph process;
- Homepage local settings do not reference the retired service ports;
- Obsidian bookmarks reference the migrated endpoints, and the Shell Commands
  configuration does not reference the old `Tools` path;
- the legacy `startup-all.bat` remains present as the explicit fallback;
- Beantime's configured authority is the vault-owned ledger outside `Tools`,
  its retained legacy copy still has the same hash, and no timer is active;
- the legacy source checkout remains at the preserved `b541089` tip on
  `feat/email-db-tool` with the five already documented residual changes;
- every tracked legacy-only path is an intentionally excluded generated file,
  local-state file, obsolete artifact, backup archive, or proposal extract;
  no unmatched application source was found;
- ignored legacy material still includes dependencies, generated output,
  settings, credentials, operational state, and the rebuildable Email
  database. None belongs in this Git repository.

The active Email runtime has its own local environment, configuration, OAuth
token, immutable pre-management OAuth backup, and database below
`NICA_STATE_ROOT`. The legacy Email database remains non-authoritative and is
not a retirement prerequisite under
[ADR-004](../adr/ADR-004-treat-email-database-as-rebuildable-local-state.md).

## Credential preservation decision

The migrated Calendar runtime has the configuration needed for its accepted
vault-event capability. Its Google integration remains disabled, so the old
Google OAuth token was deliberately not copied into the new state root. The
token is therefore not an active dependency, but it is unique recovery
material inside the legacy checkout.

Marc chose preservation on 2026-10-08. A recovery-only copy now exists below
`NICA_STATE_ROOT/calendar/backups/legacy-google-oauth-pre-retirement/`.
Publication used create-new semantics, JSON parsing and SHA-256 verification;
the source remained untouched. The recovery file disables inherited Windows
permissions and grants access only to the current user, local administrators,
and SYSTEM.

The backup is not part of the active Calendar profile and does not enable
Google integration. Restoring it later must be an explicit credential recovery
or reauthorization operation.

No token content or hash is recorded in this repository.

## Observation checklist

- [x] Record the observation start as 2026-10-08.
- [x] Confirm the aggregate launcher and linked tools through the normal
  workspace workflow.
- [x] Complete the initial read-only process, configuration, source, and state
  audit.
- [ ] Use the repository-owned workspace for at least seven normal-use days
  (earliest review: 2026-10-15; preferred two-week review: 2026-10-22).
- [ ] Record and resolve any fallback, startup, write, or persistence issue
  discovered during normal work.
- [ ] Confirm the selected services still start cleanly after a normal machine
  restart or full workspace stop/start.

## Final rollback rehearsal

Perform this only at an agreed low-impact time and do not run both
installations concurrently.

- [ ] Confirm no Beantime timer or other in-progress write is active.
- [ ] Record the new workspace's healthy status.
- [ ] Stop the repository-owned workspace with `stop-workspace.cmd`.
- [ ] Start the retained legacy `startup-all.bat` and verify the fallback is
  usable within the agreed five-minute window.
- [ ] Stop the legacy processes before restarting the new workspace.
- [ ] Start `start-workspace.cmd` and verify Homepage, Calendar, VaultGraph,
  Email, NICA Fava, and TOHU Fava independently.
- [ ] Confirm the new workspace remains the accepted daily installation.

The rehearsal verifies recovery only. It must not apply an Email export,
create a project or event, start or stop a timer, or perform another
authoritative write merely for testing.

## Pre-retirement checklist

- [x] Confirm active processes and local settings do not depend on the old
  checkout.
- [x] Confirm no unmatched legacy application source remains.
- [x] Confirm authoritative Beantime data lives outside the old checkout.
- [x] Confirm the legacy Email database is not a migration requirement.
- [x] Preserve the Calendar Google OAuth token as a verified, access-restricted
  recovery copy outside Git and Nextcloud.
- [ ] Complete the final rollback rehearsal.
- [ ] Confirm the GitHub repository and local `main` contain the accepted
  migration history.
- [ ] Confirm the legacy checkout has no new source changes after this audit.
- [ ] Obtain explicit approval before renaming or relocating the checkout.

## Retirement sequence

1. Re-run the read-only dependency and dirty-worktree checks.
2. Confirm the existing OAuth recovery copy remains available while its
   contents stay outside Git and logs.
3. Preserve the old checkout by renaming it to a clearly dated retirement
   archive; do not delete it on the first retirement pass.
4. Update or disable only the legacy launchers that would otherwise point at a
   missing `Tools` directory. Keep a documented recovery command.
5. Start the new workspace and repeat the six-service health check.
6. Observe the archived state briefly before considering deletion.
7. Delete the archive only after separate explicit approval and after deciding
   the retention of credentials, databases, generated output, and the
   unsanitized Git history.

## Rollback after archival rename

If a missed dependency appears, stop the new workspace, restore the archive's
original `Tools` name, and use the retained legacy launcher. Renaming is the
first retirement operation precisely because it is reversible; deletion is
not.
