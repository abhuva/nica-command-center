# Gate 5: Homepage shell cutover

**Status:** technical verification complete; normal-workflow acceptance pending

**Date:** 2026-10-07

**Branch:** `migration/homepage-shell-cutover`

The migrated Homepage shell is running at
`http://127.0.0.1:4274/home.html?module=bookmarks`. It combines Bookmarks,
Clock, and the already accepted website monitor. The legacy Homepage remains
running on port `4174` as warm rollback and continues to provide New Project
and Beantime while those capabilities await separate cutovers.

## Boundaries and profile

- The vault remains authoritative for `.obsidian/bookmarks.json` and Obsidian
  theme state. Its filesystem path and Obsidian vault name are explicit runtime
  inputs and are not committed.
- Homepage preferences and monitoring history live below
  `%LOCALAPPDATA%\NICA\CommandCenter\live\homepage`.
- The shell imports only the legacy UI, Bookmark, and Clock preferences. It
  retains the accepted migrated Updo settings and history.
- Only `bookmarks`, `clock`, and `updo` are enabled. New Project, Beantime,
  VaultGraph, and Email remain disabled in this process.
- VaultGraph and Email remain independently available at their accepted service
  URLs. The legacy Homepage supplies the two not-yet-cut-over mutating modules.
- The shell runs with `NICA_WRITE_ENABLED=false` and
  `NICA_OBSIDIAN_ACTIONS_ENABLED=false`. Settings, bookmark opening, search,
  project, Beantime, and monitor-restart POST requests remain blocked.

## Start and stop

The first start previews and then prepares the shell profile:

```powershell
.\scripts\start-homepage.ps1 -VaultRoot "C:\path\to\vault" -ObsidianVaultName "vault-name" -PrepareShellProfile
.\scripts\start-homepage.ps1 -VaultRoot "C:\path\to\vault" -ObsidianVaultName "vault-name" -PrepareShellProfile -Apply
```

Later starts reuse the retained profile:

```powershell
.\scripts\start-homepage.ps1 -VaultRoot "C:\path\to\vault" -ObsidianVaultName "vault-name" -Apply
```

Stop only this process with:

```powershell
.\scripts\stop-homepage.ps1
```

The launcher refuses occupied ports, either Homepage process manifest, an
invalid runtime profile, unexpected enabled modules, missing monitoring
targets, or a vault/state overlap. It verifies read-only health, authority,
Bookmarks, and the Updo child before reporting success. The stop command
validates the manifest, exact server command line, and expected child-process
types before stopping anything.

## Profile backup and rollback

The first preparation preserves the accepted monitoring-only settings at
`config/settings.monitoring-only.json` and records the active profile at
`config/runtime-profile.json`. A later preparation reuses that backup only
when it is semantically identical to the current monitoring-only settings; it
never overwrites a differing backup.

To roll back the combined shell to monitoring-only on port `4274`:

```powershell
.\scripts\stop-homepage.ps1
.\scripts\restore-monitoring-profile.ps1
.\scripts\restore-monitoring-profile.ps1 -Apply
.\scripts\start-monitoring.ps1 -VaultRoot "C:\path\to\vault" -Apply
```

The legacy Homepage on port `4174` stays warm throughout, so Bookmarks, New
Project, Beantime, and the legacy monitor remain immediately available even
during the short profile restart.

## Verification evidence

- A synthetic cutover enabled exactly Bookmarks, Clock, and Updo, loaded one
  synthetic bookmark group with two entries, and kept one synthetic monitor
  target running.
- Settings, bookmark-open, search, and monitor-restart POST requests all
  returned HTTP 403 in the synthetic shell.
- A synthetic rollback restored the monitoring-only profile, restarted it,
  then repeated the shell cutover using the retained backup. The
  monitoring-only launcher refused to start while the shell profile was
  active.
- An occupied-port apply against the live monitoring instance failed before
  changing its profile or process.
- Live Bookmark reads matched the legacy aggregate: six root groups and 39
  leaf entries. No bookmark payload was copied into repository fixtures or
  logs.
- The accepted monitoring state retained all five targets and continued
  appending its local history across cutover, restart, rollback, and restore.
- Playwright MCP verified Bookmarks and Website Monitoring navigation, five
  monitoring cards, chart rendering, the migration marker, no horizontal
  overflow at 375 px, and a clean browser console.
- Explicit `ObsidianVaultName` configuration restored theme mirroring; the
  theme endpoint returned HTTP 200 after restart.
- The live rollback rehearsal restored monitoring-only on port `4274` while
  the legacy Homepage stayed healthy, then returned to the combined shell.
- Calendar, legacy Homepage, VaultGraph, and Email remained listening during
  the cutover.

## Acceptance

Technical verification is complete. Acceptance remains pending until Marc
opens the port `4274` shell through the normal Obsidian workflow and confirms
that Bookmarks, Clock, and Website Monitoring are usable. The legacy Homepage
and all source files remain intact until then.
