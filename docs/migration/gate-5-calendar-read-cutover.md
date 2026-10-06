# Gate 5: Calendar read cutover

**Status:** accepted

**Date:** 2026-10-07

**Branch:** `migration/calendar-read-cutover`

The migrated read-only Calendar is running at
`http://127.0.0.1:4273/cal.html`. The legacy Calendar remains running on port
`4173` as warm rollback. This cutover covers vault, Google, and Nextcloud
reads only; Calendar writes and public publishing remain deferred.

## Authorities, credentials, and state

- The vault remains authoritative for Markdown event notes and Obsidian Base
  queries.
- Google Calendar and Nextcloud CalDAV remain authoritative for their remote
  events.
- Derived event output, filter state, logs, process manifests, and the filtered
  read profile live below `%LOCALAPPDATA%\NICA\CommandCenter\live\calendar`.
- `NICA_CALENDAR_ENV_FILE` points the migrated process at that external profile.
  When it is set, repository-local `.env.local` is not loaded.
- First-time initialization extracts only Base/Inbox settings, the Google API
  key and calendar IDs, and the Nextcloud CalDAV read configuration.
- Google OAuth client credentials and token, Google/Nextcloud create targets,
  Calendar API token, and SFTP publishing credentials are not copied.
- The legacy `.env.local`, OAuth token, generated output, filter state, public
  export, process, and source checkout remain unchanged.

The existing task to rotate the previously exposed Google API key remains
open. The key is retained only in local secret files and is never emitted to
plans, logs, fixtures, or Git.

## Runtime behavior

The reader starts with `NICA_WRITE_ENABLED=false` and
`NICA_OBSIDIAN_ACTIONS_ENABLED=false`. All POST routes and Google OAuth
start/callback return HTTP 403. The UI disables refresh, publishing, OAuth
controls, external-create toggles, date selection, event dragging, and event
resizing. Read-only source toggles, date navigation, printing, settings, and
event previews remain available.

External source failures are isolated. Startup records each source status and
event count without logging payloads; a transient or unavailable source does
not prevent vault events or another remote source from loading.

## Start, stop, and rollback

Preview first-time initialization, then apply it:

```powershell
.\scripts\start-calendar-read.ps1 -VaultRoot "C:\path\to\vault" -ObsidianVaultName "vault-name" -InitializeReadProfile
.\scripts\start-calendar-read.ps1 -VaultRoot "C:\path\to\vault" -ObsidianVaultName "vault-name" -InitializeReadProfile -Apply
```

Later starts reuse the retained profile:

```powershell
.\scripts\start-calendar-read.ps1 -VaultRoot "C:\path\to\vault" -ObsidianVaultName "vault-name" -Apply
```

Rollback is immediate because the legacy process never stops:

```powershell
.\scripts\stop-calendar-read.ps1
obsidian web url="http://127.0.0.1:4173/cal.html"
```

The launcher refuses vault/state overlap, unsupported or incomplete profile
keys, insecure non-loopback CalDAV URLs, occupied ports, existing manifests,
and profile overwrite. The stop command validates the exact repository server
process and confirms the port is closed before removing its manifest.

## Verification evidence

- Plan-only mode created neither state nor a listener and displayed key names
  and counts without secret values.
- A synthetic profile copied only seven permitted settings, loaded one
  synthetic Markdown event and one synthetic CalDAV event, and excluded all
  OAuth/write/publishing credentials.
- Six synthetic write and OAuth routes returned HTTP 403. Repeated profile
  initialization and occupied-port startup were refused without overwrite or
  process changes.
- Synthetic stop/restart retained the filtered profile and derived bundle.
- Playwright MCP verified synthetic year navigation, local plus CalDAV event
  rendering, disabled create controls, the migration marker, and no horizontal
  overflow at 375 px.
- The live derived bundle contains 66 events and matches the legacy generated
  bundle byte-for-byte.
- For the fixed 2025-01-01 through 2027-12-31 comparison window, both live
  processes returned the same 87 Nextcloud events with identical normalized
  payload hashes.
- The migrated Google API-key reader returned 727 events for that fixed window.
  The legacy OAuth-backed Google endpoint returned HTTP 502 during the baseline,
  so no false equality claim is made for that source.
- Playwright MCP verified both remote source toggles, 457 rendered current-year
  event instances, disabled mutation controls and dragging, responsive layout,
  and a clean browser console on the live candidate.
- Stopping the candidate closed only port `4273`; the legacy Calendar remained
  healthy on `4173` and its responsive UI was verified before candidate restart.

## Acceptance

Technical verification passed, and Marc confirmed on 2026-10-07 that vault,
Google, and Nextcloud events are usable through the normal Obsidian workflow
on port `4273`. Calendar reads are accepted as the fourth Gate 5 capability.
The legacy Calendar and all write credentials remain intact until later
capability-specific cutovers.
