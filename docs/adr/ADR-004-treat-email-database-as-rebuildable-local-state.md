# ADR-004: Treat the Email database as rebuildable local state

**Status**: Accepted

**Date**: 2026-10-07

**Participants**: Marc Bielert and Codex-assisted migration work

## Context

The Email tool stores fetched messages, mailbox synchronization metadata,
classification results, tags, rules, and export metadata in SQLite. The legacy
database lived beside the vault-local tool, and the migration initially created
a consistent local snapshot so candidate behavior could be compared safely.

That snapshot was useful for verifying the migrated software, but it does not
need to become permanent production data. The source messages remain available
from the configured mail accounts, filtering has only recently started, and
Marc confirmed that the current classifications can be recreated without
material loss. The tool itself still needs a product-completion pass.

An active WAL-backed SQLite database is also unsuitable for synchronization
through Nextcloud. Its main file and WAL/SHM companions form one live state,
and file synchronization is not a transactional database transport.

This decision refines the software/data separation established by
[ADR-001](ADR-001-separate-operational-software-from-the-shared-vault.md) and
the runtime-state boundary in
[ADR-002](ADR-002-explicit-vault-and-local-state-roots.md).

## Decision

We decided that:

1. Configured mail accounts remain authoritative for original messages.
2. The Email SQLite database is rebuildable, sensitive local working state
   below `NICA_STATE_ROOT`; it is neither vault authority nor repository data.
3. The completed Email tool must be able to initialize an empty database and
   refetch mail without copying the legacy database.
4. Existing Markdown notes under the vault's `8. Emails/` directory remain
   generated human-readable projections. They are not imported into SQLite as
   an alternative message authority.
5. Account configuration, credentials, and OAuth tokens have separate local
   secret/configuration lifecycles. Reusing them does not require reusing the
   database.
6. The previously previewed 515-note export batch is not a migration
   prerequisite and will not be applied merely to preserve the old database's
   selection state.
7. The existing databases may remain temporarily as rollback or development
   references, but their long-term migration and backup are not prerequisites
   for retiring the vault-local software.

## Alternatives considered

### Migrate the legacy database as durable production state

This would preserve classifications and sync metadata exactly. It was rejected
because the state is early, reproducible, and tied to an unfinished workflow;
making its migration critical would preserve accidental history and complicate
the software cutover.

### Keep the active SQLite database in Nextcloud

This would place data in the shared workspace, but it would expose confidential
mail state broadly and risk inconsistent synchronization of a live WAL-backed
database. It was rejected.

### Export every included message before discarding the database

This would preserve the current selection as Markdown, including the pending
515-note batch. It was rejected as a migration requirement because that batch
is a discretionary content-export action, not necessary to preserve the source
messages or move the software.

## Consequences

- (+) Email software can be completed without inheriting an unfinished
  database as permanent state.
- (+) Fresh installations have a deterministic empty-database and refetch
  path.
- (+) Git and Nextcloud remain free of the active SQLite database and bulk mail
  cache.
- (+) The unapplied 515-note batch no longer blocks tool migration.
- (-) Discarding a database loses its local classifications, tags, rules, and
  export bookkeeping unless they are recreated.
- (-) Refetching depends on source messages still being retained by the mail
  accounts.
- (-) A fresh database may need to reconcile fetched messages with existing
  vault projections before exporting to avoid duplicates.
- (=) Credentials and OAuth tokens remain sensitive local state and require
  their own setup or reauthorization path.
- (=) Existing databases are not deleted automatically; retirement remains an
  explicit later action.
