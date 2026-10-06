# Gate 1 preservation record

**Status**: Complete

**Completed**: 2026-10-06

Gate 1 preserved the current source work and created recovery artifacts without
changing production paths, launchers, configuration, or authoritative data.

## Preserved source commits

The former `Tools` checkout remains on `feat/email-db-tool`. Its preserved tip
is `b541089`.

| Commit | Purpose | Paths preserved |
| --- | --- | --- |
| `70ff594` | Refine the Email dashboard and rule management | Four Email frontend/backend files |
| `b541089` | Render timed Calendar events as blocks | Calendar frontend, server export, and documentation |

The branch also retains its existing Email foundation commit `030cfc9`.

No generated Calendar event payload, credential, local database, architecture
copy, or bytecode cache was included in these commits.

## Validation evidence

- Root ESLint check passed before preservation.
- Root JSDoc lint check passed before preservation.
- Email syntax and isolated database/export smoke checks passed.
- Calendar syntax, live Base build, and generated-event smoke checks passed with
  66 events.
- Both root lint checks passed again after the Calendar build.
- The production Calendar, Homepage, Email, NICA Fava, and TOHU Fava endpoints
  returned HTTP 200 after the commits and backups were complete.
- Playwright MCP verified the production Email Dashboard/Rules tab transition
  and an 800 px layout without horizontal overflow. It also verified Calendar
  rendering at 800 px: day-grid events used block display and solid styling,
  background events remained distinct, and the page had no horizontal
  overflow. The only console errors were missing optional favicon files.

## Recovery artifacts

Two local-only recovery artifacts were created outside Nextcloud and outside
both Git working trees:

1. A complete Git bundle containing all 11 source refs, including the preserved
   feature-branch tip. `git bundle verify` confirmed complete history.
2. A transactionally consistent Email SQLite snapshot created with SQLite's
   online backup API. `PRAGMA quick_check` returned `ok`.

The backup location is intentionally not recorded in Git because it is
machine-specific. The bundle is sensitive: it contains the unsanitized source
history and must never be pushed to the destination remote. The Email snapshot
contains operational data and must never be committed or synchronized as
software.

Credentials and tokens were not duplicated. The unchanged production checkout
continues to hold the current local configuration and is the recovery source
until the relevant capability cutover defines its secure transfer procedure.

## Intentionally residual source changes

The production checkout remains operational with the following material left
unstaged:

- the generated Calendar event bundle;
- duplicate/superseded architecture documents and their source link;
- test-generated Python bytecode.

These paths are neither migration input nor accepted destination content. Gate
2 will work from a disposable clone of committed refs, so it does not require
destructive cleanup of the production checkout.

## Rollback position

No runtime switch occurred. Production continues from the same checkout and
the same launchers. The existing endpoints remained healthy, so no rollback was
needed.
