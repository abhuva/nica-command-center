# Former Tools repository migration

**Status**: Gates 0 through 6 complete; Gate 7 observation started 2026-10-08

**Former production source**: the `Tools` checkout inside the configured NICA vault

The repository-owned workspace is now the accepted daily installation. The
vault-local checkout remains recoverable through Gate 7 as the retirement
fallback.

## Working documents

- [Migration runbook](tools-migration-runbook.md)
- [Capability and state inventory](tools-inventory.md)
- [Production baseline snapshot](production-baseline.md)
- [Gate 1 preservation record](gate-1-preservation.md)
- [Gate 2 sanitized-history import record](gate-2-sanitized-import.md)
- [Gate 3 candidate runtime record](gate-3-candidate-runtime.md)
- [Gate 4 shadow verification record](gate-4-shadow-verification.md)
- [Gate 5 VaultGraph cutover record](gate-5-vaultgraph-cutover.md)
- [Gate 5 monitoring cutover record](gate-5-monitoring-cutover.md)
- [Gate 5 Homepage shell cutover record](gate-5-homepage-shell-cutover.md)
- [Gate 5 Calendar read cutover record](gate-5-calendar-read-cutover.md)
- [Gate 5 project creation cutover record](gate-5-project-creation-cutover.md)
- [Gate 5 Calendar vault-event creation record](gate-5-calendar-vault-write-cutover.md)
- [Gate 5 Email read-only shadow record](gate-5-email-read-shadow.md)
- [Gate 5 Email bounded-fetch shadow record](gate-5-email-fetch-shadow.md)
- [Gate 5 Email bounded-classification shadow record](gate-5-email-classification-shadow.md)
- [Gate 5 Email bounded-OAuth shadow record](gate-5-email-oauth-shadow.md)
- [Gate 5 Email bounded-export shadow record](gate-5-email-export-shadow.md)
- [Gate 5 Beantime synthetic-shadow record](gate-5-beantime-shadow.md)
- [Gate 5 Beantime tool-cutover record](gate-5-beantime-tool-cutover.md)
- [Gate 6 Email stable-runtime record](gate-6-email-stable-runtime.md)
- [Gate 6 aggregate-workspace launcher record](gate-6-aggregate-workspace-launcher.md)
- [Gate 7 observation and retirement record](gate-7-retirement.md)

These documents are operational plans. Accepted, long-lived architecture
decisions remain in `docs/adr/`.

## Gate status

| Gate | Purpose | Status |
| --- | --- | --- |
| 0 | Record baseline, boundaries, acceptance checks, and rollback rules | Complete |
| 1 | Preserve source work and create recoverable backups | Complete |
| 2 | Import sanitized history into an isolated candidate branch | Complete |
| 3 | Remove vault-location assumptions and isolate candidate state | Complete |
| 4 | Shadow-test capabilities without production writes | Complete; external credentials deferred |
| 5 | Cut over one capability at a time | Complete; thirteen capabilities accepted; Beantime remains authoritative in Nextcloud at its vault-owned path, while Email database migration and the previously previewed 515-note export batch are not migration requirements |
| 6 | Switch the stable launcher | Complete; Email stable runtime and the aggregate one-button workspace are accepted |
| 7 | Observe, rehearse rollback, and retire the old checkout | In progress; initial read-only retirement audit complete, old checkout retained as fallback |

Gate 0 changes documentation only. It must not change the source checkout,
vault launchers, live configuration, credentials, or runtime state.

## Gate 0 decisions

- Preserve useful source history through a sanitized-history import.
- Track `Architecture Overview.canvas` as repository documentation.
- Keep local Obsidian configuration under `.obsidian/` ignored.
- Use a private `abhuva/nica-command-center` GitHub repository as the current
  remote copy. No additional backup system is planned during Gate 0.
