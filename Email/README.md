# Email Tool

> Migration candidate: set absolute `NICA_VAULT_ROOT` and `NICA_STATE_ROOT`
> values before serving. The database, config, OAuth tokens, and PID file live
> below `NICA_STATE_ROOT\email`. All POST actions default to disabled unless
> `NICA_WRITE_ENABLED=true`.

Database-first email bridge for the Obsidian vault.

The tool fetches email into a local SQLite database, applies local rules/tags, and exports only selected messages into the vault's `8. Emails/` folder. IMAP flags are not used as processing state.

## Start

```powershell
npm.cmd --prefix .\Email run preview
```

Open:

```text
http://127.0.0.1:4176/email.html
```

## Local Config

For the legacy tool, create `Email/config.local.json` from
`config.example.json`. Migrated runtime configuration belongs below
`NICA_STATE_ROOT\email`, not in this repository.

Secrets are read from `Tools/Email/.env.local`, `Tools/Email/.env`, or the process environment.

Use `ssl: true` for implicit TLS on port 993. Use `ssl: false` plus `starttls: true` for port 143 servers that require STARTTLS before login.

## Data Model

- `email.db` stores fetched messages, tags, rules, exports, and account sync state.
- Markdown files in `8. Emails/` are generated projections and can be regenerated.
- Stable export filenames use account, date, sender, subject, and a message hash.

## Workflow

1. Configure accounts.
2. Fetch by date range, UID range, or all messages.
3. Apply blacklist/whitelist/tag rules in SQLite.
4. Review/filter in the local UI.
5. Export included/candidate messages to `8. Emails/`.

## Validation

```powershell
npm.cmd --prefix .\Email run check:smoke
npm run check:email-read-shadow
```

## Gate 5 read-only shadow

The migrated shadow runs on port `4276` from a consistent SQLite backup. The
backup API reads the live WAL-backed database as one transactionally consistent
snapshot; `.db-wal` and `.db-shm` files are never copied separately.

Preview the authority and snapshot action without changing any process or file:

```powershell
.\scripts\start-email-read.ps1 -VaultRoot "C:\path\to\vault" -RefreshSnapshot
```

After reviewing the plan, create or refresh the isolated snapshot and start the
shadow:

```powershell
.\scripts\start-email-read.ps1 -VaultRoot "C:\path\to\vault" -RefreshSnapshot -Apply
```

Stop only the shadow while retaining its local snapshot:

```powershell
.\scripts\stop-email-read.ps1
```

No Email configuration, password environment file, or OAuth token is copied.
The shadow starts with `NICA_WRITE_ENABLED=false`; all POST routes return HTTP
403, and the UI disables fetch, count, OAuth, classification, rule, tag, and
export controls. Legacy Email `4176` remains the production workflow.
