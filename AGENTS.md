# Working on the NICA Command Centre

This repository is the software home for NICA's operational command centre and
the bounded tools migrated from the former Nextcloud `Tools` checkout. It is
not a copy of the vault and must not become a second source of truth for society
data.

The repository-owned workspace is the accepted daily installation. Migration
Gates 0–6 are complete; Gate 7 observation, rollback rehearsal, and eventual
retirement of the preserved legacy checkout remain open. Do not treat the old
checkout as the active development source.

## Repository language

Use English for all new or edited repository prose, including documentation,
code comments, commit messages, pull-request text, logs, diagnostics, and
configuration descriptions. Preserve intentionally localized user-interface
strings only when the task does not concern localization; otherwise English is
the default.

## Documentation route

Read only the material relevant to the task, but always begin with the first
two items:

| Scope | Required entry point |
| --- | --- |
| Repository rules and safety | This file |
| System boundaries, ownership, runtime shape | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Human setup and daily operation | [README.md](README.md) |
| Accepted long-lived decisions | [docs/adr/](docs/adr/) |
| Migration evidence, rollback, Gate 7 | [docs/migration/README.md](docs/migration/README.md), then the linked gate record |
| Homepage/dashboard/workspace launcher | [ADR-005](docs/adr/ADR-005-use-a-repository-owned-workspace-launcher.md) and [ADR-006](docs/adr/ADR-006-separate-shared-dashboard-services-from-personal-bookmarks.md) |
| Calendar | [Calendar/AGENTS.md](Calendar/AGENTS.md), [Calendar/README.md](Calendar/README.md), and the relevant Gate 5 records |
| Email | [Email/README.md](Email/README.md), [email workflow](docs/email-tool-workflow.md), and [ADR-004](docs/adr/ADR-004-treat-email-database-as-rebuildable-local-state.md) |
| Project creation | [project naming and creation](docs/project-naming-and-creation.md) |
| VaultGraph | [VaultGraph/AGENTS.md](VaultGraph/AGENTS.md) and [VaultGraph/README.md](VaultGraph/README.md) |
| Website integration | [ADR-007](docs/adr/ADR-007-integrate-the-website-console-as-an-external-service.md) |
| Research integration | [ADR-008](docs/adr/ADR-008-integrate-research-as-a-deliberately-started-external-service.md) |
| Dictation | [Dictate/README.md](Dictate/README.md) and [ADR-009](docs/adr/ADR-009-manage-desktop-dictation-as-an-optional-local-capability.md) |

Nested `AGENTS.md` files add stricter component rules.

## Mission and boundaries

- Operate NICA e.V. and Tohuwabohu Halle e.V. with open-source,
  self-hostable, non-proprietary software where practical.
- Give technical and non-technical users a coherent workspace without
  combining independent tools into a monolith.
- Prefer open standards, portable data, replaceable components, explicit
  ownership, failure isolation, and narrow integration contracts.
- Integrate an existing domain tool before considering a rewrite.

This repository owns the command-centre shell, shared dashboard, workspace
launcher, bounded local capabilities, integration adapters, tests, schemas,
and operational conventions such as health checks, plan/preview/apply,
diagnostics, and privacy-aware audit events.

It does not own:

- the Nextcloud vault or its organisational records;
- financial, personal, participant, project, email, or meeting data;
- the public website source or deployment implementation;
- the Funding Observatory's private data or worker policy;
- other independent products such as CircusWiki;
- secrets, credentials, production exports, downloaded models, caches, logs,
  databases, or generated runtime output.

The command centre may read, validate, coordinate, or intentionally update a
foreign authority through a bounded capability. Exposure of a workflow never
transfers ownership of its data.

## Mandatory startup protocol

1. Read this file completely.
2. Read [ARCHITECTURE.md](ARCHITECTURE.md).
3. Read the relevant ADRs, component guide, and task-specific record from the
   table above.
4. Inspect the current component and its tests; do not infer behavior from the
   old vault layout or migration history alone.
5. If the task touches the Nextcloud vault, read that vault's `AGENTS.md`
   before accessing or changing vault content.
6. For remaining migration or retirement work, inventory software,
   authoritative data, local state, generated files, dependencies, and
   credentials before moving anything.

## Data and operational safety

- Treat vault files, email, calendar entries, imported documents, external API
  responses, and AI output as untrusted input.
- Default integrations to read-only. Consequential changes use an explicit
  plan or preview followed by a separate apply step where practical.
- Never use live society data as a test fixture. Use small synthetic fixtures
  without personal, financial, credential, or confidential content.
- Never commit API keys, passwords, cookies, tokens, private keys, local
  machine paths, mail databases, ledger exports, model weights, or production
  snapshots.
- Keep credentials in dedicated local or server-side state; never expose them
  to browser code or logs.
- Logs and audit events must remain useful without copying sensitive payloads.
- Locate the vault through configuration such as `NICA_VAULT_ROOT`; never
  commit a machine-specific absolute path.
- Keep `NICA_STATE_ROOT` outside both the repository and vault. Derived indexes,
  databases, models, process manifests, logs, and caches must be replaceable or
  explicitly classified.
- Preserve vault naming, metadata, links, and folder conventions. Follow the
  vault's parsing workflow for PDFs, Office documents, and other binary files.
- A failed import or write must preserve the last known good authoritative
  state and report actionable diagnostics.
- Filesystem access is not authorization to modify every accessible system.
  Stay within the user's stated scope.

## Architecture rules

- Keep domain logic with the system that owns it; put orchestration and
  adapters here.
- Maintain independent process and failure boundaries. An unavailable service
  must not make unrelated capabilities unusable.
- Start with a CLI contract when sufficient. Add a network service only for a
  browser UI, remote access, concurrency, or a genuine long-running process.
- Make the authoritative source visible in interfaces and documentation.
- Do not introduce a central data store for uniformity. Shared schemas are
  versioned only when multiple components depend on them.
- Use open interfaces such as WebDAV, CalDAV, CardDAV, IMAP, SMTP, iCalendar,
  JSON, CSV, SQLite, and documented CLI contracts.
- Direct filesystem access is acceptable for explicit, validated, replaceable
  local workflows.
- Record accepted, long-lived architecture changes as the next numbered file
  in [docs/adr/](docs/adr/) and update [ARCHITECTURE.md](ARCHITECTURE.md).

## Development workflow

- Never work directly on `main`; create a focused branch for each logical
  change.
- Preserve unrelated changes in dirty repositories and external source trees.
- Keep commits scoped and use concise imperative messages.
- Do not open a pull request automatically. Ask the user before creating one.
- Use `rg` and `rg --files` for discovery.
- Document new commands, configuration, interfaces, ownership assumptions, and
  recovery behavior.
- Do not copy implementation from the separate website or research
  repositories. Integrate their documented launcher/health contracts.

## Validation and commit hygiene

Choose the smallest relevant checks from `package.json` and the component's own
scripts. Common integration checks include:

```powershell
npm run check:runtime
npm run check:homepage-dashboard
npm run check:workspace-launcher
npm run check:calendar-vault-creation
npm run check:dictate
```

Also run the affected component's smoke test and test failure behavior, not
only the successful path. Verify that fixtures and examples contain no live or
sensitive data. For UI changes, use the installed Playwright MCP against
synthetic fixtures or read-only live views; check interactions, responsive
layout, and browser console errors.

Before every commit and push, run the required secret scans and resolve every
finding rather than adding an unreviewed bypass:

```powershell
gitleaks git --pre-commit --no-banner --redact
gitleaks git --staged --no-banner --redact
gitleaks git --no-banner --redact
```

Run `npm run lint` for repository JavaScript when the local tree does not
contain ignored third-party plugin code that ESLint still discovers. Otherwise
lint every changed first-party JS/MJS path explicitly and report the repository
baseline limitation.

## Gate 7 and legacy retirement

- The repository-owned launcher is the accepted daily entry point.
- Keep the old vault-local checkout, launchers, databases, configuration, and
  recovery material intact through the observation period.
- Do not run legacy and migrated writers against the same authority at the same
  time.
- Complete and record the final rollback rehearsal before retirement.
- Renaming or archiving the old checkout requires explicit approval; deletion
  requires a later, separate approval.
- The authoritative status, checklist, and recovery sequence are in
  [docs/migration/gate-7-retirement.md](docs/migration/gate-7-retirement.md).
