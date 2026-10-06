# Former Tools repository migration

**Status**: Gates 0 through 3 complete; Gate 4 not started

**Production source**: the `Tools` checkout inside the configured NICA vault

The migration must preserve Marc's daily working environment. The existing
vault checkout remains the production installation until each capability has
passed its acceptance checks and has a tested rollback path.

## Working documents

- [Migration runbook](tools-migration-runbook.md)
- [Capability and state inventory](tools-inventory.md)
- [Production baseline snapshot](production-baseline.md)
- [Gate 1 preservation record](gate-1-preservation.md)
- [Gate 2 sanitized-history import record](gate-2-sanitized-import.md)
- [Gate 3 candidate runtime record](gate-3-candidate-runtime.md)

These documents are operational plans. Accepted, long-lived architecture
decisions remain in `docs/adr/`.

## Gate status

| Gate | Purpose | Status |
| --- | --- | --- |
| 0 | Record baseline, boundaries, acceptance checks, and rollback rules | Complete |
| 1 | Preserve source work and create recoverable backups | Complete |
| 2 | Import sanitized history into an isolated candidate branch | Complete |
| 3 | Remove vault-location assumptions and isolate candidate state | Complete |
| 4 | Shadow-test capabilities without production writes | Not started |
| 5 | Cut over one capability at a time | Not started |
| 6 | Switch the stable launcher | Not started |
| 7 | Observe, rehearse rollback, and retire the old checkout | Not started |

Gate 0 changes documentation only. It must not change the source checkout,
vault launchers, live configuration, credentials, or runtime state.

## Gate 0 decisions

- Preserve useful source history through a sanitized-history import.
- Track `Architecture Overview.canvas` as repository documentation.
- Keep local Obsidian configuration under `.obsidian/` ignored.
- Use a private `abhuva/nica-command-center` GitHub repository as the current
  remote copy. No additional backup system is planned during Gate 0.
