# ADR-001: Separate operational software from the shared vault

**Status**: Accepted

**Date**: 2026-10-06

**Participants**: Marc Bielert and Codex-assisted architecture discussion

## Context

The NICA Nextcloud vault is the shared operational and knowledge workspace for
NICA e.V. and Tohuwabohu Halle e.V. It contains administration, projects,
financial and legal records, contacts, meetings, Markdown knowledge, and many
binary documents. Most collaborators are non-technical and work through the
Nextcloud web interface. Some already find ordinary file synchronization
difficult.

Software has grown alongside this workspace. Known capabilities include email
tools, calendar and project-event handling, research AI, website translation
and deployment, event publication, monitoring, time tracking, and Obsidian
integrations. Some of this software currently lives in the nested `Tools` Git
repository inside the synchronized vault. Beancount data is also selectively
managed with Git while remaining part of the vault.

Co-location originally made it easier for coding agents to access both software
and live data. Agents can now be granted explicit access across the local
filesystem, so physical co-location is no longer required for that purpose.

The current synchronization rules exclude `.git`. Consequently, Nextcloud
synchronizes the `Tools` working tree but not its local Git metadata. Dependency
trees, generated files, and executable scripts can nevertheless be synchronized
through the shared vault. This creates two independent change mechanisms--Git
and Nextcloud synchronization--acting on the same working tree.

Git is valuable for source code and for selected text-based data such as
Beancount, but these uses have different ownership semantics:

- Tool source is software; Git is its source of truth.
- Beancount ledgers are organisational records; the vault is their natural
  location, with Git providing additional history and review.
- The complete vault is a mixed human workspace containing large binaries,
  sensitive records, and web-edited files; Git is not its collaboration model.

## Decision

We decided to use the following boundaries:

1. The complete Nextcloud vault will not become a Git repository.
2. Operational software will live in one or more Git repositories outside the
   synchronized vault. This clean repository will house the future NICA
   operations/command-centre software instead of treating the nested `Tools`
   checkout as the permanent structure.
3. The vault will remain the source of truth for organisational records and
   shared human-authored data.
4. Selected data collections may remain in narrowly scoped Git repositories
   inside the vault when Git history is materially useful. Beancount ledgers
   are the primary current example. Their placement follows data ownership, not
   the placement rule for software.
5. Small launchers or integration pointers may remain in the vault when they
   provide a simple entry point for local users. They must invoke installed or
   separately checked-out tools rather than contain the application itself.
6. Tools will access the vault through explicit configuration or open
   interfaces rather than relying on their source tree being physically nested
   inside the vault.

This decision concerns repository and filesystem boundaries. It does not yet
choose the command centre's implementation language, hosting model, deployment
method, authentication system, or exact repository decomposition.

## Alternatives considered

### Keep the `Tools` working tree inside the vault

This preserves simple relative paths, automatic distribution through
Nextcloud, and the current one-click startup arrangement. It was rejected as
the long-term default because Git metadata is not synchronized, Git and
Nextcloud can race on the same files, dependencies and generated files create
sync churn, and non-technical web users receive little benefit from having
source code in the shared data workspace.

### Put the complete vault under Git

This would give useful diffs for Markdown and a unified history. It was rejected
because the vault contains large binary files, sensitive and personal records,
folder-specific sharing boundaries, and edits made through the Nextcloud web
interface. Git would not improve the collaborators' workflow and would create
ambiguous authorship, permanent sensitive history, repository growth, and a
second conflict-management system.

### Put all tools into one monolithic application

This could simplify installation initially. It was rejected as an architectural
goal because website publishing, research, email, finance, and calendar tooling
have different lifecycles and failure modes. A command centre should coordinate
capabilities through stable interfaces without requiring every tool to become
one application.

### Keep every tool entirely independent

This maximizes local autonomy but leaves no shared operational overview and
duplicates configuration, status, audit, and workflow logic. The intended
direction is a thin command centre with modular tools, not an unconnected
collection of scripts.

## Consequences

- (+) Software development uses normal Git branches, reviews, tests, releases,
  and dependency management without Nextcloud modifying the working tree.
- (+) The shared vault remains understandable and usable through the web for
  non-technical collaborators.
- (+) Code, organisational data, generated state, and credentials can have
  explicit and different ownership and access rules.
- (+) Independent tools can continue evolving while becoming visible through a
  common command centre.
- (+) A future hosted interface can serve web-only users without placing source
  code in their shared folders.
- (-) Technical workstations require a separate installation or checkout.
- (-) Existing relative paths and startup scripts must be migrated to explicit
  configuration or a stable launcher command.
- (-) Compatibility between tool versions and vault schemas must be made
  explicit.
- (-) Moving the current tools requires an inventory of authoritative data,
  local state, caches, generated files, and credentials before anything is
  relocated.
- (=) Beancount and other narrowly scoped data repositories require their own
  privacy, retention, remote-access, and authorship rules.
- (=) Coding agents may work across repositories and vault data only when the
  task grants that scope; filesystem separation is not treated as the security
  boundary.

## Follow-up decisions

The clean repository must document separate decisions for:

- command-centre scope and repository decomposition;
- local-only versus hosted operation for web-only collaborators;
- tool discovery and CLI/API contracts;
- authentication, authorization, credentials, and audit logging;
- vault schema/version compatibility and migrations;
- handling of derived indexes, caches, and generated artifacts;
- Beancount repository boundaries and privacy controls;
- installation, upgrades, rollback, and recovery.
