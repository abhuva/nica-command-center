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
npm run check:email-fetch-shadow
npm run check:email-classification-shadow
npm run check:email-oauth-shadow
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

## Gate 5 bounded-fetch shadow

Email POST routes are protected by operation-specific server capabilities.
Preview the copy of the existing local profile and a consistent snapshot
refresh without changing files or processes:

```powershell
.\scripts\start-email-fetch-shadow.ps1 -VaultRoot "C:\path\to\vault" -PrepareFetchProfile -RefreshSnapshot
```

After reviewing the plan, stop only the migrated `4276` read shadow and apply
the bounded profile:

```powershell
.\scripts\stop-email-read.ps1
.\scripts\start-email-fetch-shadow.ps1 -VaultRoot "C:\path\to\vault" -PrepareFetchProfile -RefreshSnapshot -Apply
```

The launcher keeps `NICA_WRITE_ENABLED=false` and enables only
`mail.count,mail.fetch`. IMAP mailboxes are opened read-only. Candidate database
and token refreshes stay in isolated local state; OAuth setup, classification,
rules, tags, and vault export remain disabled. Legacy Email `4176` remains the
production workflow and immediate fallback.

## Gate 5 bounded-classification shadow

The classification profile retains Count/Fetch and additionally enables only
`message.tag`, `rules.apply`, and `rules.manage`. Preview the profile and its
consistent candidate-database rollback snapshot without changing state:

```powershell
.\scripts\start-email-classification-shadow.ps1 -VaultRoot "C:\path\to\vault" -BackupCandidate
```

After review, stop only migrated `4276` and apply the profile:

```powershell
.\scripts\stop-email-read.ps1
.\scripts\start-email-classification-shadow.ps1 -VaultRoot "C:\path\to\vault" -BackupCandidate -Apply
```

OAuth setup and vault export remain disabled. Roll back to the accepted
fetch-only authority by stopping the process and running
`start-email-fetch-shadow.ps1` with `-Apply` and without a snapshot refresh.
The pre-classification database snapshot remains below local runtime state at
`email/backups/email-before-classification.db` for state recovery if required.
Repeating `-BackupCandidate` retains that file. To replace it deliberately, use
`-RefreshCandidateBackup`; the first refresh preserves the prior recovery copy
as `email/backups/email-before-classification.original.db`.

## Gate 5 bounded-OAuth shadow

The OAuth profile retains Count/Fetch and classification and adds only
`oauth.manage` for interactive Microsoft login and reauthorization. Automatic
access-token refresh during fetch already belongs to `mail.fetch`. Preview the
profile and immutable token-backup action first:

```powershell
.\scripts\start-email-oauth-shadow.ps1 -VaultRoot "C:\path\to\vault" -BackupOAuthTokens
```

After review, stop only migrated `4276` and apply the profile:

```powershell
.\scripts\stop-email-read.ps1
.\scripts\start-email-oauth-shadow.ps1 -VaultRoot "C:\path\to\vault" -BackupOAuthTokens -Apply
```

The loopback callback port defaults to `8080` and can be changed with
`-OAuthCallbackPort` or `EMAIL_OAUTH_CALLBACK_PORT` when the provider's
registered redirect URI permits it. Token recovery copies live under
`email/backups/oauth-before-management/` in local runtime state and are not
overwritten by normal restarts. Vault export remains disabled. Roll back by
stopping the process and starting `start-email-classification-shadow.ps1` with
`-Apply` and no profile or database refresh.
