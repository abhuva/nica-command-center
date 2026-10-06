# Gate 5: website monitoring cutover

**Status:** technical cutover complete; normal-workflow confirmation pending

**Date:** 2026-10-07

**Branch:** `migration/monitoring-cutover`

Website monitoring is the second Gate 5 capability. Because the legacy `updo`
integration is embedded in Homepage, the migrated capability runs a
monitoring-only Homepage instance at
`http://127.0.0.1:4274/home.html?module=updo`. The production Homepage and its
monitor remain available on port `4174` as warm rollback.

## Inventory and boundaries

- Production monitoring had five HTTPS targets, all without URL user info,
  query strings, or fragments.
- `updo` 0.4.6 is installed locally and remains the domain monitor.
- The legacy state comprised raw samples, compressed summaries, incidents, and
  a compression cursor under the former `Tools/data/updo` directory.
- The migrated copy lives below
  `%LOCALAPPDATA%\NICA\CommandCenter\live\homepage` and is not authoritative
  society data.
- The candidate imports only the `updo` configuration. Bookmarks, project
  creation, Beantime, VaultGraph, Email, and Clock are disabled in this
  component instance.
- `NICA_WRITE_ENABLED` remains false. Settings, project creation, monitor
  restart, and every other POST endpoint continue to return `403
  NICA_READ_ONLY`.
- Monitoring writes only its isolated, replaceable local history and sends
  read-only `HEAD` requests to configured targets. It does not write to the
  vault or remote services and requires no credentials.

The legacy and migrated monitors both remain active during observation. This
doubles the small read-only probe load but keeps immediate rollback and a
continuously current legacy history. Their local state paths are separate.

## Launcher and state migration

The component launcher is plan-first. First-time initialization requires an
explicit flag and refuses to overwrite an existing destination:

```powershell
.\scripts\start-monitoring.ps1 -VaultRoot "C:\path\to\vault" -InitializeFromLegacy
.\scripts\start-monitoring.ps1 -VaultRoot "C:\path\to\vault" -InitializeFromLegacy -Apply
```

Later restarts use the retained local configuration and history:

```powershell
.\scripts\start-monitoring.ps1 -VaultRoot "C:\path\to\vault" -Apply
.\scripts\stop-monitoring.ps1
```

Initialization snapshots the legacy settings and four state files only when
their size and modification timestamps remain stable across the copy. Every
JSON and JSONL file is parsed before the staged snapshot is moved into place.
Target URLs containing user info, query strings, or fragments are rejected for
manual review instead of being copied silently.

The start script refuses occupied ports and validates Homepage health,
read-only mode, authority, state path, monitor process, and target count. The
stop script validates the exact repository process and its expected Windows
child-process types before stopping Node and `updo`; configuration and history
remain in place.

## Verification evidence

- Synthetic plan-only mode created neither state nor a listener.
- A synthetic legacy snapshot imported one target plus raw, summary, incident,
  and cursor data. Restart preserved all fixture history.
- A repeated initialization was rejected without overwriting retained state.
- An occupied-port test against production Homepage failed without stopping or
  disturbing either Homepage instance.
- Unrelated settings, project, and monitor-restart POST requests returned HTTP
  403 in the monitoring-only candidate.
- Playwright MCP verified direct `?module=updo` selection, the migration marker,
  five status cards, chart rendering, 15-minute and 7-day controls, manual
  reload, and no horizontal overflow at 375 px width.
- The migrated snapshot retained five targets, 516 compressed summaries, and
  3,986 incident records from the validated legacy snapshot. All targets had
  current samples and the monitor reported no process error.
- Candidate stop completed in about 2.7 seconds. The legacy UI remained healthy
  with five targets and no error. Candidate restoration completed in about 3.3
  seconds, well within the five-minute rollback objective.
- Calendar, production Homepage, VaultGraph, and Email remained healthy during
  the component cutover.

The candidate console reports only the pre-existing missing local favicon.

## Rollback

Stop the migrated monitor and continue using the already-running production
Homepage:

```powershell
.\scripts\stop-monitoring.ps1
```

Open Homepage on port `4174` and select the Website Monitoring tab. No legacy
restart or state restore is required because that monitor remains warm and was
verified through Playwright during the rehearsal.

## Remaining acceptance

The technical checks pass. Monitoring is accepted only after Marc confirms the
normal monitoring workflow is usable at the port `4274` URL. Both histories
and the legacy implementation remain retained throughout the observation
period.
