# NICA Command Centre Architecture

**Status:** Operational architecture accepted; migration Gate 7 observation is
in progress

**Updated:** 2026-10-09

## Documentation entry points

- [README.md](README.md) is the human-facing introduction, setup guide, and
  daily operating reference.
- [AGENTS.md](AGENTS.md) defines mandatory rules for agents and contributors.
- [docs/adr/](docs/adr/) contains accepted, long-lived architecture decisions.
- [docs/migration/README.md](docs/migration/README.md) indexes the historical
  migration, cutover, rollback, and retirement evidence.
- [Architecture Overview.canvas](Architecture%20Overview.canvas) is the visual
  companion; this document is authoritative when they differ.

## Purpose

The Command Centre gives NICA e.V. and Tohuwabohu Halle e.V. one coherent
local workspace for operational tools while preserving the ownership and
failure boundaries of those tools. It favors open-source, self-hostable and
portable components, but it does not combine every workflow or datum into one
application.

The architecture optimizes for:

- explicit sources of truth;
- replaceable components and open interfaces;
- bounded, reviewable writes;
- useful local operation without putting software into Nextcloud;
- independent failures and recovery paths;
- later evolution toward browser-accessible operation where needed.

## Core boundaries

### Nextcloud is the shared human workspace

The vault remains authoritative for organisational documents, projects,
contacts, event notes, Beancount ledgers, and other shared records. Its
machine-specific path is configuration, never repository state. The Command
Centre may provide validated workflows around vault content but does not become
its owner.

### Git repositories own software

This repository owns the Command Centre shell and bounded capabilities migrated
from the former vault-local `Tools` checkout. Substantial independent products,
including the public website and Funding Observatory, retain their own
repositories, releases, dependencies, data, and credentials.

### Local state is private and replaceable

`NICA_STATE_ROOT` contains process manifests, logs, settings, caches, generated
indexes, downloaded models, Email SQLite state, and component configuration.
It must be outside both Git and the vault. A local artifact is not an
organisational authority merely because a service depends on it.

### Integration does not transfer ownership

The Command Centre starts, checks, opens, or coordinates a domain tool through
a narrow CLI or loopback HTTP contract. Domain-specific mutation logic remains
with the owning component. No universal tool protocol or central data store is
required.

## Current runtime shape

```text
User / Obsidian Webviewer
          |
          v
Homepage + shared Dashboard (127.0.0.1:4274)
          |
          +--> Calendar (4273) --------> calendar sources + vault event notes
          +--> Email (4276) -----------> mail servers + local SQLite + vault exports
          +--> VaultGraph (4175) ------> derived view of the vault
          +--> NICA / TOHU Fava (4998/4999) -> vault-owned Beancount ledgers
          +--> Website console (8787) ------> separate nica-website repository
          +--> Funding Observatory (8767) --> separate research repository/private data
          +--> Dictate ----------------> focused desktop application

start-workspace.cmd
          |
          v
short-lived PowerShell reconciler
  - reads local workspace profile and Homepage settings
  - starts or retains selected independent processes
  - validates health and process ownership
  - records an aggregate result, opens selected views, then exits
```

Homepage is the required control surface. Calendar, Email, Website, Research,
VaultGraph, finance services, and Dictate have independent lifecycles. Projects
and Contacts are shared navigation capabilities rather than background
services. Dashboard entries are versioned and shared; personal Obsidian
bookmarks remain user-owned.

## Capability placement

| Capability | Implementation owner | Authoritative data | Runtime notes |
| --- | --- | --- | --- |
| Homepage, Dashboard, Settings | This repository | Versioned defaults plus machine-local overrides | Required loopback service |
| Workspace launcher | This repository | Local workspace profile | Reconciles services and exits |
| Calendar | This repository | External calendar sources and vault event notes | Reads external sources; only the accepted vault-event write is enabled |
| Email | This repository | Mail accounts; exported Markdown is a vault projection | SQLite database is sensitive, local, and rebuildable |
| Project creation and Contacts navigation | This repository around vault conventions | Nextcloud vault | Fixed paths and validated project templates/names |
| Beantime and finance views | This repository around Beancount/Fava | Vault-owned ledgers | Timer state is local; completed entries append to the configured ledger |
| VaultGraph | This repository | Nextcloud vault | Graph data is derived and rebuildable |
| Website monitoring | This repository | Remote endpoints | Measurements and incidents are local derived history |
| Website console | `nica-website` repository | Website source and deployment system | Command Centre manages only configured startup, health, and navigation |
| Funding Observatory | `research-agent` repository | Private research database, profiles, sources, and results | Manual start is distinct from opt-in auto-start; active work is not force-stopped |
| Dictate | This repository's adapter and pinned upstream snapshot | Focused application's text field | Runtime/models are local; only one model is loaded; no transcript history |

An unavailable capability degrades only its own entry. The Homepage and other
independent services must remain usable.

## Authority and storage model

| Material | Primary authority | Required treatment |
| --- | --- | --- |
| Software source, tests, schemas, documentation | Owning Git repository | Branch, review, test, release |
| Shared organisational records | Nextcloud vault | Preserve names, metadata, links, provenance, and permissions |
| Mail messages | Originating mail servers | Fetch read-only; do not use IMAP flags as local workflow state |
| Email working database | Machine-local state | Sensitive and rebuildable; never synchronize or commit |
| Beancount ledgers | Configured vault paths | Validate before use; never duplicate merely for architecture symmetry |
| Website source and deployment credentials | `nica-website` repository/local secrets | Never proxy or copy into the Command Centre |
| Research data and worker policy | Funding Observatory | Private external state; Command Centre sees only bounded health/lifecycle metadata |
| Downloaded speech models and Python runtimes | Machine-local state | Verified, replaceable, optional, and excluded from Git/Nextcloud |
| Credentials and tokens | Dedicated component-local secret storage | Never expose to browser code, Git, fixtures, or logs |
| Generated indexes, monitoring history, logs, PID files | Owning component's local state | Rebuildable or explicitly retained; non-authoritative |
| Audit events | Owning component or Command Centre | Minimal, attributable, and free of sensitive payloads |

## Configuration and lifecycle

`scripts/configure-workspace.ps1` validates the vault, optional external
repositories, private research state, ledger paths, and unique ports. It writes
the machine-local workspace profile only after a separate `-Apply` invocation.
Credentials are not part of that profile.

Homepage Settings stores normalized local choices below `NICA_STATE_ROOT`:

- which services should be reconciled on the next workspace start;
- which shared Dashboard entries are visible;
- module and theme preferences;
- Dictate activation, model, hotkey, and minimum hold duration.

Saving settings does not silently stop a running service. The next launcher run
performs reconciliation. Research visibility and automatic startup are
deliberately separate because starting its host may resume queued work.

Every managed process has a component-specific manifest and health contract.
Startup retains a process only when repository, component, state root, port,
authority, and expected command identity match. Shutdown stops only a matching
owned process; active Research work is refused rather than force-terminated.

## Write and trust model

- Reads, imported content, remote responses, vault files, messages, and AI
  output are untrusted input.
- Consequential operations use plan/preview followed by explicit apply where
  practical.
- Write authority is capability-specific. A broad environment switch is not a
  substitute for validating the requested operation.
- Browser actions are same-origin and server allow-listed; browser payloads do
  not supply arbitrary local paths or service URLs.
- Services bind to loopback by default. External repositories retain their own
  authentication, CSRF, deployment, and worker controls.
- Tests use synthetic fixtures. Live verification is read-only unless a
  controlled write is explicitly authorized and recoverable.
- Logs and audit records contain diagnostics and identifiers, not credentials,
  message bodies, transcripts, or other sensitive payloads.

## Accepted architecture decisions

| ADR | Decision |
| --- | --- |
| [ADR-001](docs/adr/ADR-001-separate-operational-software-from-the-shared-vault.md) | Keep operational software outside the shared vault |
| [ADR-002](docs/adr/ADR-002-explicit-vault-and-local-state-roots.md) | Use explicit vault and local-state roots |
| [ADR-003](docs/adr/ADR-003-use-operation-specific-capability-interlocks.md) | Gate writes with operation-specific capabilities |
| [ADR-004](docs/adr/ADR-004-treat-email-database-as-rebuildable-local-state.md) | Treat the Email database as rebuildable local state |
| [ADR-005](docs/adr/ADR-005-use-a-repository-owned-workspace-launcher.md) | Use a repository-owned aggregate launcher |
| [ADR-006](docs/adr/ADR-006-separate-shared-dashboard-services-from-personal-bookmarks.md) | Separate shared Dashboard services from personal bookmarks |
| [ADR-007](docs/adr/ADR-007-integrate-the-website-console-as-an-external-service.md) | Integrate the website console as an external service |
| [ADR-008](docs/adr/ADR-008-integrate-research-as-a-deliberately-started-external-service.md) | Integrate Research as a deliberately started external service |
| [ADR-009](docs/adr/ADR-009-manage-desktop-dictation-as-an-optional-local-capability.md) | Manage desktop dictation as an optional local capability |

## Migration and current phase

The sanitized import, isolated runtime, shadow verification, per-capability
cutovers, stable Email runtime, and aggregate launcher are complete. The
repository-owned workspace is the accepted daily installation. Gate 7 now
requires normal-use observation, a final rollback rehearsal, and explicit
approval before the old checkout is first archived and later deleted.

Migration history is evidence, not current operating instruction. Start at the
[migration index](docs/migration/README.md); use the
[Gate 7 record](docs/migration/gate-7-retirement.md) for the only active gate.

## Non-goals

- Replacing Nextcloud or Obsidian.
- Putting the complete vault or society data into Git.
- Teaching non-technical collaborators to operate Git repositories.
- Combining every capability into one server, database, or release cycle.
- Copying website or research implementation into this repository.
- Making confidential data public in the name of open software.
- Rewriting working tools solely to make the architecture uniform.

## Open evolution questions

1. Which workflows need a secured hosted interface for collaborators who do
   not run the local workspace?
2. How should hosted users authenticate without exposing vault or component
   credentials to browser code?
3. Which launcher and health contracts have enough independent consumers to
   justify a shared, versioned schema?
4. Which dedicated secret-storage, rotation, and recovery mechanism should
   replace today's component-local arrangements?
5. Which future domain services should be hosted by NICA, and which should
   remain integrations with replaceable external providers?

These questions must be answered from real operating evidence. They do not
justify a central platform, database, or protocol in advance.
