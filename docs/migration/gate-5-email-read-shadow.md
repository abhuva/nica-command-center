# Gate 5: Email read-only shadow

**Status:** read-only shadow accepted; Email writes remain legacy-only

**Date:** 2026-10-07

**Branch:** `migration/email-read-shadow`

The first Email migration slice is a read-only shadow on port `4276`. Legacy
Email `4176` remains the production workflow and is neither stopped nor
reconfigured.

## Inventory and boundaries

- The legacy process on `4176` is healthy and uses Python from the vault-local
  `Tools/Email` checkout.
- The live SQLite database is WAL-backed and has active `.db-wal` and `.db-shm`
  companions. Copying the main database file alone is not a valid snapshot.
- Legacy configuration, password environment files, provider credentials, and
  OAuth token files remain in the legacy installation. Their contents were not
  copied or used for candidate verification.
- The database and mail bodies are confidential local operational state. They
  remain excluded from Git, fixtures, logs, and browser automation evidence.
- The vault remains authoritative for exported Markdown under `8. Emails/`.
  The shadow cannot export or otherwise modify that directory.

## Snapshot contract

`Email/snapshot_db.py` uses SQLite's online backup API against a read-only
source connection. It includes committed WAL state, verifies the candidate with
`PRAGMA quick_check`, and atomically replaces only the isolated destination
snapshot. WAL and SHM files are never copied as independent files.

The launcher defaults to plan-only behavior. `-RefreshSnapshot -Apply` is
required to create or refresh the snapshot. Later starts may retain the last
verified snapshot by omitting `-RefreshSnapshot`.

## Runtime contract

- Candidate URL: `http://127.0.0.1:4276/email.html`
- Candidate state: `NICA_STATE_ROOT\email`
- Candidate mode: `read-only`
- All POST routes return HTTP 403 before parsing or executing their payload.
- UI write controls are disabled after `/api/ping` confirms read-only mode.
- No IMAP password, OAuth credential/token, or account configuration file is
  copied into candidate state.
- Legacy `4176` is the immediate rollback and remains running throughout the
  shadow period.

## Commands

```powershell
# Plan only
.\scripts\start-email-read.ps1 -VaultRoot "C:\path\to\vault" -RefreshSnapshot

# Create/refresh isolated snapshot and start 4276
.\scripts\start-email-read.ps1 -VaultRoot "C:\path\to\vault" -RefreshSnapshot -Apply

# Stop only 4276; retain snapshot and logs
.\scripts\stop-email-read.ps1
```

## Verification evidence

- The synthetic WAL-backed source was backed up, refreshed, and passed SQLite
  `quick_check` without copying its WAL or SHM companions.
- The synthetic server started in `read-only` mode; every POST route returned
  HTTP 403 before any mail, OAuth, rule, tag, or export operation ran.
- Playwright MCP verified the read-only badge, disabled mutation controls,
  working read navigation, no horizontal overflow at 375 px, and no browser
  warnings or errors.
- Stop and restart retained the isolated snapshot while legacy Email `4176`
  remained healthy.
- The live plan-only preview found the expected WAL-backed source, selected
  isolated local state and port `4276`, excluded credentials and OAuth tokens,
  and changed no process or file.
- The live apply created a verified consistent snapshot and started `4276` in
  read-only mode. Aggregate message, account, and rule counts matched legacy
  `4176` without logging or recording any mail payload.
- Every live candidate POST route returned HTTP 403, no credential/config/token
  file was present in candidate state, and legacy `4176` remained healthy.
- Live stop/restart retained the candidate snapshot and restored `4276` without
  refreshing or touching the legacy database.

## Acceptance checklist

- [x] Inventory software, live database companions, configuration, credentials,
  tokens, generated projections, and process ownership without reading payloads.
- [x] Keep legacy Email `4176` healthy and unchanged.
- [x] Implement a consistent, verified SQLite snapshot instead of copying live
  database files directly.
- [x] Keep candidate credentials and OAuth tokens absent.
- [x] Disable all candidate POST routes and visible UI mutation controls.
- [x] Pass synthetic API and Playwright MCP verification.
- [x] Review a plan against the live authority without creating a snapshot or
  changing a process.
- [x] Apply the read-only shadow on `4276` with a fresh consistent snapshot.
- [x] Confirm aggregate counts without recording email payloads.
- [x] Confirm the normal read workflow without recording email payloads.
- [x] Rehearse stop/restart while legacy `4176` remains available.
- [x] Marc confirms the normal read-only workflow is usable.
