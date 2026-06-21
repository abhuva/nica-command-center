# Email Tool

Database-first email bridge for the Obsidian vault.

The tool fetches email into a local SQLite database, applies local rules/tags, and exports only selected messages into the vault's `8. Emails/` folder. IMAP flags are not used as processing state.

## Start

```powershell
npm.cmd --prefix .\Tools\Email run preview
```

Open:

```text
http://127.0.0.1:4176/email.html
```

## Local Config

Create `Tools/Email/config.local.json` from `config.example.json`. This file is gitignored.

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
npm.cmd --prefix .\Tools\Email run check:smoke
```
