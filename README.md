# NICA Command Centre

The NICA Command Centre is the local workspace for the operational tools used
by NICA e.V. and Tohuwabohu Halle e.V. It starts the required services, provides
shared entry points through a Homepage, and connects them to the Nextcloud vault
without copying the responsible domain systems into one monolithic application.

**Status:** Migration from the former vault-local `Tools` checkout is complete
through Gate 6. This repository is the accepted daily installation. Gate 7 is
the active observation and fallback phase; the old checkout remains available
until retirement receives explicit approval. The plan requires at least seven,
preferably fourteen, days of normal use and a final rollback rehearsal. The
current status is recorded in the
[Gate 7 record](docs/migration/gate-7-retirement.md).

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) explains system boundaries, data
  authority, components, and durable architecture decisions.
- [AGENTS.md](AGENTS.md) is the mandatory entry point for coding agents and
  technical contributors changing this repository.
- [docs/migration/README.md](docs/migration/README.md) indexes migration,
  cutover, and rollback evidence.
- Numbered [Architecture Decision Records](docs/adr/) preserve long-lived
  decisions.

## What belongs to the Command Centre

| Area | Function | Owner / data authority |
| --- | --- | --- |
| Homepage and Dashboard | Shared navigation, settings, and startup choices | This repository; local settings below the state root |
| Calendar | Calendar view and bounded creation of event notes | Calendar sources and vault notes remain authoritative |
| Email | Fetching, local rules/tags, and controlled Markdown export | Mail servers are authoritative; SQLite is sensitive, rebuildable local working state |
| Projects and Contacts | Fixed shared entry points and project creation | Nextcloud vault |
| Beantime and Fava | Time tracking and NICA/TOHU accounting views | Beancount files in the vault |
| VaultGraph and monitoring | Derived visualization and availability data | Vault or external targets; history is a local derivative |
| Website | Start and open the development/deployment console | Separate `nica-website` repository |
| Research | Deliberately start/open the Funding Observatory | Separate `research-agent` repository and private data directory |
| Dictate | Optional local dictation into the focused text field | Local runtime/models; the target application owns the inserted text |

Personal Obsidian bookmarks remain independent from the shared Dashboard. A
disabled or unavailable service must not make unrelated services unusable.

## Prerequisites

The current workstation setup targets Windows and PowerShell. A complete local
installation requires:

- Git, Node.js, and npm;
- Python 3.10 or newer for Email and optional Dictate;
- Obsidian with CLI access for Webviewer and vault actions;
- Fava on `PATH` for the Beancount interfaces;
- a local Nextcloud vault and separately managed service credentials.

Install the JavaScript dependencies for the Command Centre and Calendar once:

```powershell
npm install
npm --prefix .\Calendar install
```

Website and Research retain their own installations, dependencies, and
credentials. Models, databases, tokens, logs, and other runtime state are not
distributed through Git or Nextcloud.

## Configure a workstation once

Machine configuration lives below
`%LOCALAPPDATA%\NICA\CommandCenter\live` by default. It contains local paths
and ports, but no credentials. Configuration is shown as a plan first and is
written only with `-Apply`:

```powershell
.\scripts\configure-workspace.ps1 `
  -VaultRoot "C:\path\to\vault" `
  -ObsidianVaultName "vault-name" `
  -WebsiteRepository "C:\path\to\nica-website" `
  -ResearchRepository "C:\path\to\research-agent" `
  -ResearchDataDirectory "C:\private\funding-observatory"

.\scripts\configure-workspace.ps1 `
  -VaultRoot "C:\path\to\vault" `
  -ObsidianVaultName "vault-name" `
  -WebsiteRepository "C:\path\to\nica-website" `
  -ResearchRepository "C:\path\to\research-agent" `
  -ResearchDataDirectory "C:\private\funding-observatory" `
  -Apply
```

Website and Research paths are optional. Supply non-default Beancount files as
vault-relative paths through `-NicaLedger` and `-TohuLedger`. An existing
profile is replaced only when `-Replace` is deliberately supplied.

`configure-workspace.ps1` does not provision secrets or create a complete
component-specific first-run configuration. The migrated workstation already
has that local configuration. On a new computer, Calendar/Email credentials
and other private state must be configured or restored separately and securely;
there is currently no universal installer.

Credentials and component-specific configuration remain in their respective
local state directories. The [Email guide](Email/README.md) and
[Dictate guide](Dictate/README.md) describe their current local setup. Technical
documentation for all other components is routed through
[AGENTS.md](AGENTS.md).

## Daily use

- `start-workspace.cmd` starts or retains the selected services and opens the
  configured Obsidian views.
- `stop-workspace.cmd` stops only processes that this repository can identify
  as its own; Obsidian remains open.
- Homepage Settings controls modules, Dashboard visibility, and the service
  selection for the next workspace start.
- The aggregate result of the last start is stored at
  `%LOCALAPPDATA%\NICA\CommandCenter\live\launcher\workspace-status.json`;
  component logs remain in their respective state directories.

The PowerShell variants show only a plan unless `-Apply` is supplied:

```powershell
.\scripts\start-workspace.ps1
.\scripts\start-workspace.ps1 -Apply
.\scripts\stop-workspace.ps1
```

Default local interfaces:

| Service | Address |
| --- | --- |
| Homepage | `http://127.0.0.1:4274/home.html` |
| Settings | `http://127.0.0.1:4274/settings.html` |
| Calendar | `http://127.0.0.1:4273/cal.html` |
| Email | `http://127.0.0.1:4276/email.html` |
| VaultGraph | `http://127.0.0.1:4175/vault-graph.html` |

Ports may differ in the local workspace profile.

## Optional dictation

Dictate is disabled by default. Install the runtime and selected models
separately on each computer; the installer verifies file size and SHA-256:

```powershell
.\scripts\setup-dictate.ps1 -Models multilingual,german
.\scripts\setup-dictate.ps1 -Models multilingual,german -Apply
```

`multilingual` is the default for German and English; `german` is the focused
German alternative. Only one model is loaded at a time. Homepage Settings
controls activation, model, hotkey, and minimum hold duration. Audio and
transcripts are not intentionally retained. See
[Dictate/README.md](Dictate/README.md) for details.

## Data and security boundaries

- The Nextcloud vault remains authoritative for organisational documents,
  projects, contacts, and Beancount data.
- Mail servers remain authoritative for messages; the Email database is
  sensitive, rebuildable local working state.
- Secrets, tokens, local paths, databases, models, and generated exports do not
  belong in Git.
- Mutating actions are narrowly bounded and use separate plan/preview and apply
  steps where practical.
- Website and Research remain independent products; the Command Centre manages
  only their local integration.

## Development and diagnostics

Read [AGENTS.md](AGENTS.md) before making changes. The main entry-point checks
are:

```powershell
npm run check:runtime
npm run check:homepage-dashboard
npm run check:workspace-launcher
```

`npm run doctor` checks a runtime-oriented installation and requires explicit
`NICA_VAULT_ROOT` and `NICA_STATE_ROOT` values.

Additional `check:*` scripts in [package.json](package.json) validate individual
integration boundaries. Domain workflows include the
[Email tool workflow](docs/email-tool-workflow.md) and
[project naming and creation rules](docs/project-naming-and-creation.md).
