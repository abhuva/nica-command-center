# Gate 5: Email bounded-OAuth shadow

**Status:** bounded-OAuth shadow accepted; Email export remains legacy-only

**Date:** 2026-10-07

## Scope

Extend the accepted Email candidate on `4276` with interactive Microsoft OAuth
login and reauthorization. The profile retains the accepted Count/Fetch and
classification capabilities and adds exactly `oauth.manage`. Vault export stays
disabled.

OAuth access-token refresh needed during an accepted `mail.fetch` operation was
already part of the bounded-fetch profile. This slice adds only the explicit
login/reauthorization workflow that starts an authorization-code flow, receives
the loopback callback, and atomically publishes refreshed token state below the
candidate runtime-state root.

Legacy Email `4176` remains available for the established workflow and as the
immediate fallback. The accepted bounded-classification profile is the candidate
rollback target.

## Safety boundaries

- The global Email write switch remains false.
- The exact allowlist is `mail.count`, `mail.fetch`, `message.tag`,
  `oauth.manage`, `rules.apply`, and `rules.manage`; `vault.export` remains
  blocked by the server and disabled in the UI.
- The callback listener binds only to `127.0.0.1`. Its port is explicit through
  `-OAuthCallbackPort` or `EMAIL_OAUTH_CALLBACK_PORT` and defaults to `8080` to
  preserve the registered legacy redirect URI.
- Callback request logs omit the query string, authorization code, and OAuth
  state.
- Token files are published through an exclusive staging file and atomic
  replacement. A provider response that omits a replacement refresh token keeps
  the latest existing refresh token; a login without any refresh token is
  rejected. The merge and publication share the fetch lock so reauthorization
  cannot overwrite a concurrent fetch-time refresh. A complete new response
  does not depend on parsing obsolete token state.
- OAuth startup automatically creates missing recovery copies for existing
  token files below `email/backups/oauth-before-management/` in local runtime
  state. Existing backups are never replaced by a normal activation or restart;
  an account without a token remains available for first-time login.
- No OAuth secret, token, authorization code, or live Email payload is copied
  into the repository or test fixtures.

## Commands

Preview the transition and token-backup action without changing files or
processes:

```powershell
.\scripts\start-email-oauth-shadow.ps1 -VaultRoot "C:\path\to\vault"
```

After reviewing the plan, stop only migrated Email `4276` and activate the
bounded profile:

```powershell
.\scripts\stop-email-read.ps1
.\scripts\start-email-oauth-shadow.ps1 -VaultRoot "C:\path\to\vault" -Apply
```

The authorization link is opened from the Email Account view. Do not copy its
query parameters into logs, issues, or chat.

## Rollback

Stop the OAuth profile and restart the accepted classification profile without
refreshing its database or credential profile:

```powershell
.\scripts\stop-email-read.ps1
.\scripts\start-email-classification-shadow.ps1 -VaultRoot "C:\path\to\vault" -Apply
```

This immediately removes interactive OAuth authority while retaining candidate
state. If a reauthorization produced unusable token state, stop the service,
preserve the failed token for diagnosis outside Git, restore the corresponding
immutable copy from `email/backups/oauth-before-management/`, and start the
classification profile.

## Verification evidence

- `npm run check:email-oauth-shadow` passed with synthetic Microsoft OAuth
  state, exact capability health, callback-state validation, query-free callback
  logging, atomic token publication, malformed-old-token replacement,
  concurrent refresh serialization, refresh-token preservation, automatic
  immutable token backup, tokenless first-time login, launcher plan/apply/stop,
  and rollback to classification.
- Playwright MCP verified the synthetic UI on `4476`: the page reported
  `Ready · bounded Email OAuth`; Count, Fetch, classification, rules, and OAuth
  were enabled; Export was disabled; the OAuth action created a Microsoft login
  link with the configured loopback callback; all observed API requests returned
  HTTP 200; the console had no warnings or errors; and a 375-by-812 viewport had
  no horizontal overflow.
- The live candidate remained on the accepted classification profile throughout
  implementation and synthetic verification.
- The live plan retained the existing candidate database and credential profile,
  found six configured accounts and one existing OAuth token, proposed one
  missing immutable token backup, kept Export disabled, and selected free
  loopback port `8080`. Both candidate `4276` and legacy `4176` were healthy;
  the plan changed no file or process.
- Activation stopped only migrated Email `4276`, created one immutable recovery
  copy for the configured OAuth token, and started the bounded-OAuth profile.
  Health reported the exact planned capabilities and `vault.export` remained
  false; a direct Export request returned HTTP 403. Legacy `4176` remained
  healthy.
- Rollback to bounded classification removed `oauth.manage` while retaining
  Count/Fetch and classification. OAuth was then restored without refreshing
  candidate state or replacing the token recovery copy.
- Live Playwright MCP verification found the OAuth account and enabled OAuth,
  Count, Fetch, and classification controls while Export remained disabled.
  All observed API calls returned HTTP 200, the console had no warnings or
  errors, and the 375-by-812 viewport had no horizontal overflow. The OAuth
  authorization link was not opened during this read-only browser check.
- Marc completed the normal Microsoft OAuth login and confirmed the
  OAuth-dependent Email workflow works on `4276` on 2026-10-07.

## Live acceptance checklist

- [x] Review a live plan showing the retained candidate profile, one or more
  configured OAuth accounts, the intended callback port, and missing-versus-
  retained token backups.
- [x] Confirm migrated `4276` and legacy `4176` are healthy before activation.
- [x] Create the immutable token recovery copy and activate the OAuth profile.
- [x] Confirm exact health capabilities and that Export remains blocked.
- [x] Complete one normal OAuth reauthorization and then Count/Fetch for that
  account.
- [x] Rehearse rollback to bounded classification.
- [x] Marc confirms the normal OAuth-dependent Email workflow is usable.
