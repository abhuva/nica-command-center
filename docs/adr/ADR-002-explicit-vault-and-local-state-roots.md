# ADR-002: Require explicit vault and local-state roots

**Status**: Accepted

**Date**: 2026-10-06

**Participants**: Marc Bielert and Codex-assisted migration work

## Context

The imported tools were written while their source checkout lived at
`<vault>/Tools`. They inferred the vault with `../..` and stored SQLite files,
generated JavaScript, filter state, OAuth tokens, settings, exports, and PID
files next to source code. That layout is unsafe once software lives in a
separate Git repository and would also make a parallel candidate capable of
silently writing to the daily production workspace.

The production checkout must remain usable throughout migration. A candidate
therefore needs distinct ports and state, an explicit data authority, and a
fail-closed mode for consequential actions.

## Decision

All migrated runtime entry points require two absolute environment variables:

- `NICA_VAULT_ROOT` identifies the existing vault, which remains authoritative.
- `NICA_STATE_ROOT` identifies replaceable local state outside both the vault
  and its repository. The two roots must be separate directory trees.

Each component owns a directory below the state root. Databases, generated
bundles, settings overrides, tokens, exports, logs, and PID files belong there.
Repository files provide code and safe defaults only.

The candidate uses separate ports and defaults to `NICA_WRITE_ENABLED=false`.
In that mode, action endpoints—including vault edits, remote calendar edits,
email ingestion/export, OAuth changes, project creation, timer changes, and
manual rebuild controls—return a read-only error. Read-only inspection may
still create or refresh replaceable local indexes and database schema under the
state root. An intentional apply run must set `NICA_WRITE_ENABLED=true`; this
switch is a migration interlock, not a substitute for future authorization or
operation-specific plan/apply contracts.

Health responses identify the component, runtime mode, authoritative vault,
and local-state directory without exposing credentials.

Obsidian CLI integration must also name its vault explicitly through
`OBSIDIAN_VAULT_NAME`. We decided that CLI reads must fail instead of retrying
against the currently active Obsidian vault. Consequential Obsidian UI actions
require both the named vault and the separate
`NICA_OBSIDIAN_ACTIONS_ENABLED=true` opt-in. Filesystem workflows may remain
available without that action opt-in when `NICA_WRITE_ENABLED=true` has been
set intentionally.

## Alternatives considered

### Preserve relative `../..` discovery

This would minimize code changes, but the repository's parent is not the vault
and different checkout locations would silently select different data. It was
rejected because an authority must never be inferred from source placement.

### Store candidate state inside the repository

Git ignores could hide the files, but credentials, databases, and generated
artifacts would still be adjacent to source and easy to commit or delete. It
was rejected in favor of an explicit local-state boundary.

### Copy production state into the candidate

This could make the candidate look complete immediately, but email databases,
tokens, and other local state may contain sensitive data and would create a
second operational copy. It was rejected for Gate 3; only synthetic fixtures
are used for automated verification.

### Enable writes because the candidate uses different ports

Ports isolate processes, not data. Both instances could still change the same
vault or external services. This was rejected in favor of a default-deny write
interlock and later workflow-specific plan/apply controls.

### Fall back to the active Obsidian vault

This preserved legacy convenience when vault targeting failed, but it made a
synthetic or alternate-root candidate capable of reading or acting on an
unrelated open vault. It was rejected in favor of explicit vault targeting and
filesystem-only fallback behavior.

## Consequences

- (+) The candidate can run beside production without sharing mutable state.
- (+) Missing or relative configuration fails at startup instead of selecting
  an accidental directory.
- (+) Runtime state is clearly non-authoritative and can be backed up or rebuilt
  according to the owning tool's needs.
- (+) Health checks make authority and write capability visible.
- (+) A synthetic candidate cannot silently cross over to the active Obsidian
  vault through CLI fallback.
- (-) Every workstation needs explicit vault and state configuration.
- (-) Existing launch and stop commands need the new environment or candidate
  scripts.
- (-) Read-only mode temporarily disables some useful UI actions until their
  apply behavior is verified.
- (-) Obsidian-derived theme, Base, and metadata features require the configured
  vault name even when `NICA_VAULT_ROOT` is already set.
- (=) Secrets remain an unresolved deployment concern and must stay in an
  untracked state/secret mechanism in the meantime.
