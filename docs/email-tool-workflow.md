# Email tool workflow

**Status**: Working product baseline

**Date**: 2026-10-07

## Purpose

The Email tool provides a private local workspace for finding operationally
relevant mail and intentionally projecting selected messages into the shared
Nextcloud vault. It is not a replacement mail server and does not make its
SQLite database authoritative.

## Intended daily workflow

1. Configure each mail account in local runtime configuration and authorize it
   with a password secret or OAuth token.
2. Use **Count** to check connectivity and available messages without changing
   mailbox state.
3. Use **Fetch New** to copy messages into the rebuildable local database. IMAP
   access remains read-only and does not use server flags as workflow state.
4. Apply local rules, then review candidate, included, and excluded messages in
   the UI. Manual tagging or include/exclude decisions may refine the rules.
5. Optionally run local spam classification in shadow mode. Review training
   examples with predictions visible and label the deterministic 20-percent
   holdout blind. These labels do not change include/exclude state or mailboxes.
6. Use **Preview Export** to reconcile included messages with existing Markdown
   projections in `8. Emails/`.
7. Use the separate **Apply Export** action only when the aggregate plan is
   expected and conflict-free.
8. Treat a lost or intentionally discarded database as a reset: initialize an
   empty database, refetch, recreate the useful rules, and reconcile against
   existing vault notes before exporting.

## Version-one completion criteria

- A fresh runtime starts without a legacy database and refuses to overwrite an
  existing database during initialization.
- Existing account configuration and OAuth setup can be reused separately from
  message state.
- Count, fetch, classification, OAuth, and preview/apply export remain bounded
  by explicit server capabilities.
- Existing vault projections are recognized without being rewritten or
  duplicated.
- Startup, shutdown, and restart preserve the selected local state root.
- Failure of one account is reported without exposing credentials or message
  content and without corrupting other account state.
- The normal UI works at desktop and narrow viewport sizes without browser
  console errors.

## Deliberately deferred product choices

The current baseline remains intentionally manual. These are product features,
not database-migration prerequisites:

- managing account configuration through the UI instead of a local file;
- scheduled background fetching instead of explicit Count/Fetch actions;
- retaining or exporting attachments rather than recording only their count;
- long-term rule libraries, bulk triage ergonomics, and retention controls;
- remote mailbox moves, provider spam reporting, or deletion based on model
  predictions;
- a destructive reset command for an existing database.

Each item should be selected from actual daily use. Until then, a fresh start
requires an empty state path rather than deleting or replacing a database
automatically.

The local-model implementation and the validation still required on the
16-GB-VRAM office workstation are documented in the
[classification workstation handoff](email-local-classification-handoff.md).
