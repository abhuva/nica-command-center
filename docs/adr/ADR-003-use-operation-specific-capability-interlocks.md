# ADR-003: Use operation-specific capability interlocks

**Status**: Accepted

**Date**: 2026-10-07

**Participants**: Marc Bielert and Codex-assisted migration work

## Context

ADR-002 established `NICA_WRITE_ENABLED` as a fail-closed migration interlock.
That binary switch is too broad for controlled cutover of a component such as
Email: enabling it exposes IMAP fetch, OAuth changes, local classification,
rules, tags, and vault export at the same time.

The migration needs to verify one consequential boundary at a time while the
legacy tool remains available. Ports and UI controls do not provide a security
boundary because a crafted HTTP request can bypass the visible interface.

## Decision

Components with several consequential operations may add a validated,
operation-specific capability allowlist. The server must enforce the allowlist
before parsing or executing a request, report the active capabilities through
its health endpoint, and keep the user interface consistent with that report.

Email uses `NICA_EMAIL_CAPABILITIES` with these explicit values:

- `mail.count`
- `mail.fetch`
- `message.tag`
- `oauth.manage`
- `rules.apply`
- `rules.manage`
- `vault.export`

Unknown values fail startup. `NICA_WRITE_ENABLED=true` remains an explicit
unrestricted compatibility mode, but migration launchers must keep it false and
enable only the capabilities accepted for that slice. Capability interlocks are
deployment safety controls, not authentication or user authorization.

The first bounded Email-fetch slice enables only `mail.count` and `mail.fetch`.
IMAP mailboxes are opened read-only; fetched messages, sync metadata, and any
refreshed OAuth token are written only under isolated local state. OAuth setup,
classification, rules, tags, and vault export remain disabled.

## Alternatives considered

### Enable the global write switch for a short test

This would require relying on the operator and UI not to invoke unrelated
routes. It was rejected because every POST route would become callable.

### Remove unrelated routes from the candidate build

This would create migration-only source variants and make later slices harder
to compare with the integrated tool. It was rejected in favor of one server
with explicit runtime capabilities.

### Rely only on disabled UI controls

This would not protect against direct or accidental HTTP requests. It was
rejected because the server is the required enforcement boundary.

## Consequences

- (+) Each mutation boundary can be tested and accepted independently.
- (+) Health checks and the UI expose the active operational authority.
- (+) Unknown or omitted capabilities fail closed.
- (+) Legacy production can remain available during bounded candidate tests.
- (-) Launchers and tests must maintain an exact route-to-capability mapping.
- (-) A later hosted deployment still requires real authentication and
  authorization; these interlocks do not provide either.
