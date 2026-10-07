# Gate 2 sanitized-history import record

**Status**: Complete

**Completed**: 2026-10-06

Gate 2 imported the former `Tools` repository's useful committed history into
the command-centre repository without changing the production checkout or its
launchers.

## Rewrite boundary

The rewrite ran in an independent disposable clone created from the preserved
source tip `b541089`. The resulting sanitized source tip is `29b0228`.

The following paths were removed from every reachable source commit:

- `data/docling-material-check/`
- `Calendar/events.generated.js`
- `Calendar/calendar.filter-state.json`
- `Calendar/build-events-backup-260329.zip`
- `timetracking/timetracking.klg`

Personal defaults were also rewritten throughout reachable history:

- the personal Beantime account example became `Zeit:Example`;
- the Email smoke fixture uses an explicitly synthetic example user.

The accepted ADR's participant attribution in the destination documentation is
not a fixture and remains unchanged.

## Rewrite and scan tooling

- `git-filter-repo` `2.47.0`, installed in a user-local migration-tools area
- Gitleaks `8.30.1`, downloaded from its official release and verified against
  the release SHA-256 checksum

Neither tool was installed system-wide or added to the repository.

## Verification before import

- `git fsck --full` passed in the rewritten clone.
- No excluded path remained in the current tree or reachable objects.
- Git history searches found no former personal fixture values.
- Gitleaks scanned 49 source commits (about 1.54 MB) with no findings.
- A reproducible root `npm ci` completed.
- Root lint and JSDoc checks passed.
- Email smoke checks passed against temporary state.
- Calendar and VaultGraph source syntax checks passed without scanning a live
  vault.

Calendar and VaultGraph full smoke checks are deferred to Gate 3 because their
current location assumptions would target the wrong parent directory outside
the vault.

## Destination import

The sanitized history was merged with destination history in merge commit
`c597350`. Destination `AGENTS.md`, `ARCHITECTURE.md`, and accepted ADRs remain
authoritative. Ignore rules were combined and now prevent regenerated Calendar
and VaultGraph outputs from re-entering Git.

Post-merge verification found:

- no excluded path in any reachable destination ref;
- no former personal fixture value in reachable history;
- no conflict markers;
- no machine-specific path introduced through conflict resolution;
- Gitleaks scanned 54 reachable commits (about 1.60 MB) with no findings;
- root lint and JSDoc checks passed;
- Email smoke checks passed;
- Calendar and VaultGraph syntax checks passed;
- `git fsck --full` reported no reachable integrity error.

The rejected first import attempt left only unreachable dangling objects in the
local object database. They are not referenced, are not part of the branch, and
cannot be transferred by a normal push. Git may garbage-collect them later.

## Known debt carried into Gate 3

- `npm ci` reports three existing advisories: one moderate and two high. Gate 2
  does not change dependencies; Gate 3 must review them before candidate use.
- Imported source retains historical CRLF line endings. Git's whitespace check
  reports carriage returns on the large imported diff. Bulk line-ending
  normalization was intentionally excluded from the history-import merge.
- Current runtime code still derives the vault from its filesystem position.
- The documented Calendar environment example is not yet a tracked portable
  template.
- Browser tests currently exercise production services. Gate 3 must launch
  isolated candidate services before candidate browser acceptance.

## Production impact and rollback

Production was not stopped, reconfigured, or pointed at the destination. A
Gate 2 rollback consists only of abandoning the destination migration branch;
the vault checkout continues to operate independently.
