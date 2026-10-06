# NICA command-centre architecture

**Status**: Foundation; implementation not started

**Date**: 2026-10-06

## Purpose

NICA is developing a growing set of digital capabilities to manage the work of
a non-profit society with open-source, self-hostable, non-proprietary software
where practical. The goal is organisational independence, portable data,
auditable operations, and the ability to create or change workflows quickly.

This repository will become the software home for the NICA command centre and
for suitable tools migrated from the shared Nextcloud vault. It begins clean so
that software, authoritative data, generated state, and credentials can be
separated deliberately instead of reproducing the current mixed layout.

The accepted repository-placement decision is recorded in
[ADR-001](docs/adr/ADR-001-separate-operational-software-from-the-shared-vault.md).

## Current operating environment

### Shared vault

The Nextcloud vault is the societies' operational and knowledge workspace. It
contains:

- society administration, finance, legal, and accounting records;
- project folders and project MOCs;
- contacts, meetings, tasks, and linked Markdown knowledge;
- Beancount ledgers and LibreOffice planning data;
- photographs, PDFs, DOCX files, spreadsheets, and other binary records;
- Obsidian configuration, templates, Bases, and helper scripts.

Most collaborators are non-technical. They primarily use the Nextcloud browser
interface and should not be required to understand Git, branches, commits, or a
developer installation.

### Known software capabilities

The current landscape includes at least:

- email ingestion, classification, database views, and exports;
- research and AI-assisted workflows;
- public website building, translation, validation, deployment, and monitoring;
- calendar generation and project-event handling;
- project creation and Obsidian integrations;
- Beancount/Fava finance views and time tracking;
- CircusWiki and related knowledge-publication tooling;
- vault visualization and operational homepage modules.

This inventory is incomplete and must be verified before migration. Every
capability may contain software, authoritative data, derived state, credentials,
or a mixture of them.

## Problem statement

The present directory structure does not consistently communicate ownership.
Software, live organisational data, generated exports, dependency trees, local
state, and credentials can be adjacent or mixed. It is therefore difficult to
answer:

- Which copy is authoritative?
- What may be regenerated or deleted?
- What should be synchronized through Nextcloud?
- What belongs in Git?
- What may a user or coding agent modify?
- What must be backed up, retained, or kept private?
- Which component owns a failed workflow?

The growing number of tools also makes discovery and coordinated operation
difficult. The desired answer is a command centre, but not a monolithic
application that absorbs every tool.

## Architectural boundaries

### Nextcloud is the human workspace and data authority

The vault remains optimized for shared documents, Markdown knowledge, project
records, web access, and non-technical collaboration. It will not be converted
into one Git repository.

### Software lives outside the synchronized vault

Software repositories use Git as their primary source of truth and live in a
normal development location. Tools receive the vault location through explicit
configuration or connect through open protocols.

This repository is the clean destination for the future command centre. Moving
the former vault `Tools` checkout is a later migration activity, not a blind
directory copy.

### Data repositories are different from software repositories

Text-based operational data can benefit from Git while remaining in its natural
vault location. Beancount is the primary example. A narrowly scoped Git
repository for ledger data does not justify putting software working trees or
the complete vault under Git.

### The command centre coordinates; domain tools retain ownership

The command centre provides one place for status, discovery, control, and
cross-tool workflows. It calls modular capabilities through stable CLI or API
interfaces. It does not copy all organisational data or require every domain
tool to share one runtime and release cycle.

### Web-only collaborators are first-class users

Co-location of source code in Nextcloud does not help people using only the
browser. Local launchers may remain useful for synchronized workstations, but a
broadly shared command centre may require a secured hosted interface or another
browser-accessible delivery model.

### Open means portable and replaceable, not universally public

Prefer open-source components, open protocols, and portable formats such as
Markdown, JSON, CSV, SQLite, iCalendar, CalDAV, CardDAV, WebDAV, IMAP, and SMTP.
Financial, personal, participant, and email data remain confidential where
required. Institutional independence comes from control and portability;
publication applies only where appropriate.

## Target conceptual architecture

```text
Non-technical collaborators
        |
        v
Nextcloud web / Obsidian / future hosted UI
        |
        v
NICA command centre
  - capability registry
  - health and status
  - plan / preview / apply workflows
  - cross-tool orchestration
  - audit and diagnostics
        |
        +----------------+----------------+----------------+
        |                |                |                |
        v                v                v                v
 Email tools       Calendar tools   Website tools    Research tools
        |                |                |                |
        +----------------+----------------+----------------+
                         |
                         v
      Nextcloud data, mail, CalDAV, Git repositories,
      Beancount ledgers, and other authoritative systems
```

The command centre may initially run locally. The architecture must not assume
that local execution alone will satisfy web-only collaborators in the long
term.

## Responsibility model

| Material | Primary authority | Expected treatment |
| --- | --- | --- |
| Software source and tests | Git repository | Branch, review, test, release |
| Shared organisational records | Nextcloud vault | Human-readable, web-accessible, governed |
| Beancount ledgers | Vault/data repository | Narrow private Git history where useful |
| Raw source documents | Vault or originating system | Preserve provenance and permissions |
| Derived indexes and caches | Owning tool | Rebuildable; excluded from synchronization and Git |
| Generated publication output | Owning workflow | Reproducible; archive only when useful |
| Credentials and tokens | Dedicated secret mechanism | Never browser-exposed or committed |
| Audit events | Command centre or owning tool | Minimal, attributable, privacy-aware |

## Command-centre principles

- Existing tools remain independently usable where practical.
- Integrate before rewriting.
- Begin with stable CLI contracts; add HTTP APIs only when remote or long-lived
  operation requires them.
- Prefer read-only status and diagnostics by default.
- Consequential changes use plan/preview/apply steps.
- Every displayed fact identifies its authoritative source.
- A failed tool degrades its own capability, not the whole command centre.
- Credentials remain server-side or local to the executing tool.
- Imported files, messages, calendar entries, and AI output are untrusted input.
- Audit information must not duplicate sensitive payloads.
- Shared schemas and interfaces are versioned when multiple components rely on
  them.

## Candidate integration contract

The exact protocol is intentionally undecided. A small CLI contract is a useful
starting hypothesis for local tools:

```text
<tool> capabilities --json
<tool> doctor --json
<tool> status --json
<tool> plan <operation> --json
<tool> apply <plan>
```

The first real integrations must test this hypothesis before it becomes a
standard. Existing tools should not be rewritten solely to conform to a
speculative abstraction.

## Migration approach

The operational working plan for migrating the former vault `Tools` checkout
without interrupting daily use is maintained in
[docs/migration/](docs/migration/README.md). It supplements this architecture;
accepted boundary decisions remain in ADRs.

### Phase 1: Inventory and classification

- [ ] List every known repository, script, service, homepage module, and
  operational launcher.
- [ ] Record owner, purpose, users, runtime, repository, and maintenance state.
- [ ] Identify inputs, outputs, authoritative data, caches, generated files,
  credentials, and external systems for each capability.
- [ ] Record current cross-tool workflows and manual handoffs.
- [ ] Identify hard-coded relative paths into the vault.
- [ ] Identify software and dependencies currently synchronized by Nextcloud.

### Phase 2: Establish the clean repository

- [x] Create the repository outside the synchronized vault.
- [x] Add the initial architecture overview, agent rules, and ADR directory.
- [ ] Decide the repository's private remote and backup arrangement.
- [x] Define configuration for locating the vault without committing a
  machine-specific path.
- [x] Define security, privacy, logging, and test-fixture rules before importing
  live integrations.
- [ ] Add a capability registry containing metadata, not copied implementations.

### Phase 3: Establish a thin command centre

- [ ] Show tool discovery, health, version, and configuration status.
- [ ] Link to or launch existing interfaces before rebuilding them.
- [ ] Integrate one low-risk, read-only workflow as the first vertical slice.
- [ ] Validate failure isolation when a registered tool is missing or unhealthy.
- [ ] Decide which users require local access and which require a hosted UI.

### Phase 4: Move and connect capabilities deliberately

- [ ] Separate authoritative data from local state in the former vault `Tools`
  directory.
- [ ] Replace relative vault assumptions with explicit configuration.
- [ ] Move software only after its data ownership and recovery path are known.
- [ ] Preserve lightweight vault launchers where they remain useful.
- [ ] Add cross-tool workflows one at a time with preview and audit behavior.
- [ ] Retire old copies only after validation and a recovery test.

## Explicit non-goals for the first version

- Replacing Nextcloud or Obsidian.
- Teaching all collaborators to use Git.
- Putting the complete vault under Git.
- Combining every tool into one deployable process.
- Copying all organisational data into a central database.
- Rewriting working tools merely to make the architecture look uniform.
- Making confidential society data public in the name of open data.

## Open decisions

1. Which existing homepage code should be migrated, reused, or retired?
2. Which capabilities belong directly in this repository, and which remain
   external tools?
3. Is the primary runtime local, centrally hosted, or hybrid?
4. How will web-only Nextcloud users authenticate to hosted operational tools?
5. What is the minimal common interface for status and controlled execution?
6. How are tool versions matched to evolving vault conventions and metadata?
7. What audit information is required for finance, email, publishing, and AI
   operations?
8. Where will secrets be stored, rotated, and recovered?
9. Which Beancount files form a repository, who may access its remote, and how
   are other financial documents excluded?
10. Which tool should provide the initial proof of integration?

## Success criteria

The architecture is succeeding when:

- collaborators can use the vault without encountering development files;
- developers can work on tools without Nextcloud modifying the working tree;
- each important datum has one clearly identified source of truth;
- dependencies, caches, and generated files are visibly non-authoritative;
- the command centre reports tool health without owning every implementation;
- a missing tool fails visibly and locally rather than breaking all operations;
- consequential actions can be previewed, attributed, and recovered;
- NICA can replace a component without losing access to its own data.
