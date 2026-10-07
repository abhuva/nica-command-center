# Former Tools migration runbook

**Status**: Gates 0 through 4 complete; Gate 5 is in progress

**Availability objective**: Marc retains a working daily toolset throughout the
migration. Individual capability cutovers may use a controlled maintenance
window of up to five minutes when immediate rollback is available.

## Non-negotiable safety rules

1. The vault `Tools` checkout remains the production installation until final
   acceptance.
2. Do not move, rename, delete, reset, or clean the production checkout as part
   of preparing the import.
3. Keep `startup-all.bat` unchanged until the stable-launcher gate.
4. Run candidate services from a separate checkout with separate ports and
   runtime state.
5. Never run two writers against the same ledger, Email database, calendar,
   export directory, or mutable vault workflow.
6. Candidate write paths default to disabled. Enable one only for its explicit
   verification or cutover.
7. Every capability requires a documented rollback command or procedure before
   its cutover begins.
8. Do not commit secrets, live data, database copies, generated vault payloads,
   or machine-specific absolute paths.
9. Keep the old installation and recovery material through the observation
   period. Retirement requires explicit approval.

## Environment roles

### Production

- Location: current `Tools` checkout inside the vault
- Entry point: current vault launchers
- Data: live authorities and current local runtime state
- Change policy: urgent fixes and narrowly scoped source-preservation commits
  only during migration

### Candidate

- Location: this repository outside Nextcloud
- Entry point: a separate, clearly named candidate launcher
- Data: synthetic fixtures or isolated snapshots until a controlled cutover
- Network: alternate ports where supported
- UI: visibly labelled as a migration candidate

Suggested shadow ports are `4273` for Calendar, `4274` for Homepage, `4275` for
VaultGraph, and `4276` for Email. These are planning defaults, not accepted
interfaces. Beantime remains disabled until its Fava port is configurable.

## Gate 0 - baseline and planning

### Actions

- [x] Record source branch, worktree, and remote state.
- [x] Capture a non-invasive production health and runtime baseline.
- [x] Inventory known capabilities, ports, inputs, writes, and local state.
- [x] Classify obvious software, generated output, credentials, local state,
  organisational material, and obsolete artifacts.
- [x] Define production/candidate boundaries and the single-writer rule.
- [x] Define per-capability cutover and rollback structure.
- [x] Select a sanitized-history import rather than a clean snapshot.
- [x] Track the intentional architecture Canvas and ignore `.obsidian/`.
- [x] Select a private `abhuva/nica-command-center` GitHub remote; no additional
  backup is required during Gate 0.
- [x] Review this runbook with Marc and accept Gate 0.

### Exit criteria

- Production files and launchers are unchanged.
- Known state and write boundaries are documented.
- No capability lacks a rollback expectation.
- Open decisions that affect implementation are explicit.

## Gate 1 - preserve source work and recovery material

**Completion**: Complete. See
[Gate 1 preservation record](gate-1-preservation.md).

### Actions

1. Capture the production commit, branch, status, dependency versions, active
   processes, and health endpoints immediately before preservation.
2. Commit only the uncommitted Email software work on its existing feature
   branch and validate it.
3. Commit only the Calendar rendering source/docs change and validate it.
4. Leave generated Calendar data and duplicate architecture documents out of
   those commits.
5. Create a recoverable bundle of committed Git refs outside both repositories.
6. Back up local operational state using state-aware procedures. In particular,
   stop Email or use SQLite's backup mechanism before copying its database.
7. Record restore checks without writing secrets or backup locations into Git.

### Exit criteria

- The active Email feature and software WIP are represented by commits.
- Git history and required local state each have a recovery path.
- The production launch command still works.
- No live or generated payload was newly committed.

### Rollback

Gate 1 does not change runtime paths. Continue using the existing checkout and
launchers. If a source commit is unsuitable, preserve it and correct it on the
feature branch; do not rewrite or reset the working production checkout.

## Gate 2 - sanitized import

**Completion**: Complete. See
[Gate 2 sanitized-history import record](gate-2-sanitized-import.md).

### Actions

1. Work from a disposable clone, not the production checkout.
2. Remove unsafe paths from every imported historical commit, including
   proposal extracts, generated Calendar events, UI state, backup archives, and
   obsolete timetracking artifacts.
3. Run a credential/history scan and resolve every finding before import.
4. Import the sanitized history into a feature branch in this repository.
5. Keep destination `AGENTS.md`, `ARCHITECTURE.md`, and accepted ADRs
   authoritative when resolving the unrelated histories.
6. Verify that excluded blobs and paths are absent from reachable imported
   history.

### Exit criteria

- All intended software capabilities exist in the candidate tree.
- Unsafe material is absent from current files and reachable history.
- The original production checkout remains unchanged and operational.

### Rollback

Delete only the disposable import branch/clone after verifying its exact path.
Production is unaffected.

## Gate 3 - candidate isolation and portability

**Completion**: Complete. See
[Gate 3 candidate runtime record](gate-3-candidate-runtime.md).

### Actions

- [x] Introduce explicit vault-root configuration; reject missing or invalid roots.
- [x] Add a separate runtime-state root for databases, generated output, logs, PIDs,
  monitoring samples, and timer state.
- [x] Make all candidate service ports configurable.
- [x] Commit safe configuration templates with empty secret values.
- [x] Add a read-only migration profile with mutating modules disabled.
- [x] Use synthetic fixtures for automated tests.
- [x] Add health/doctor output that identifies the authoritative source and whether
  writes are enabled.
- [x] Create a candidate launcher without modifying the production launcher.

### Exit criteria

- Candidate startup never depends on being nested inside the vault.
- Candidate startup cannot silently write to production state.
- Missing tools or configuration degrade only their own capability.
- Reproducible lint, smoke, and failure-path checks pass.

## Gate 4 - shadow verification

**Completion**: Complete for local-vault, isolated-state, and synthetic-write
workflows. See [Gate 4 shadow verification](gate-4-shadow-verification.md).
Credential-dependent Google Calendar, Nextcloud CalDAV, and IMAP verification
remains a Gate 5 prerequisite and was not enabled during the shadow run.

Run read-only and isolated capabilities in this order:

1. VaultGraph
2. Homepage shell with mutating modules disabled
3. Website monitoring with separate state
4. Calendar reads
5. Email UI against a consistent database snapshot
6. Project creation against a synthetic vault
7. Calendar writes against disposable test events
8. Email fetch/export in a bounded test
9. Beantime against a synthetic ledger

For every capability, record:

- start/stop behavior;
- health response;
- Obsidian Webviewer behavior;
- comparison with production reads;
- restart/persistence behavior;
- failure isolation;
- any write performed and its cleanup;
- measured rollback time.

### Exit criteria

- Each capability has evidence for its acceptance checks.
- No unplanned production write occurred.
- Rollback instructions have been rehearsed where possible.

## Gate 5 - per-capability cutover

**Progress:** VaultGraph is accepted. Its migrated server is running at the
existing daily URL with a rehearsed legacy rollback, and Marc confirmed the
normal Obsidian workflow on 2026-10-06. Monitoring is also accepted with a warm
legacy rollback; Marc confirmed the normal monitoring workflow on 2026-10-07.
The Homepage shell is accepted after technical cutover, rollback verification,
and Marc's normal Obsidian workflow confirmation on 2026-10-07. See [Gate 5
VaultGraph cutover](gate-5-vaultgraph-cutover.md), [Gate 5 monitoring
cutover](gate-5-monitoring-cutover.md), and [Gate 5 Homepage shell
cutover](gate-5-homepage-shell-cutover.md). Calendar reads are accepted after
technical cutover, rollback verification, and Marc's normal Obsidian workflow
confirmation on 2026-10-07. See [Gate 5 Calendar read
cutover](gate-5-calendar-read-cutover.md). Project creation is accepted after
technical cutover, rollback verification, a confirmed normal workflow, and a
post-fix live-vault metadata probe on 2026-10-07. The write authority remains
limited to `project.create`, and legacy Homepage `4174` remains the warm
fallback. See [Gate 5 project creation
cutover](gate-5-project-creation-cutover.md).

Calendar vault-event creation is accepted after technical cutover, rollback
verification, and Marc's normal workflow confirmation on 2026-10-07. Live
`4273` enables only `vault-event.create`; Google, CalDAV, OAuth, edit, rebuild,
Obsidian-action, and publishing routes remain disabled. Legacy Calendar `4173`
remains the warm fallback. See [Gate 5 Calendar vault-event creation
cutover](gate-5-calendar-vault-write-cutover.md).

Email reads are accepted on the `4276` read-only shadow after consistent
snapshot verification, API and browser checks, aggregate count comparison,
stop/restart rehearsal, and Marc's normal workflow confirmation on 2026-10-07.
All fetch, OAuth, classification, rule, tag, export, and other write operations
remain disabled there. Legacy Email `4176` remains production for writes and
the warm fallback for reads. See [Gate 5 Email read-only shadow
record](gate-5-email-read-shadow.md).

The bounded Email fetch shadow is accepted after synthetic API and launcher
checks, Playwright MCP verification, live bounded Count/Fetch, rollback
rehearsal, and Marc's normal-workflow confirmation on 2026-10-07. Candidate
`4276` enables only `mail.count` and `mail.fetch`; OAuth setup, classification,
rules, tags, and vault export remain blocked. Legacy Email `4176` remains the
production workflow for those operations and the warm fallback. See [Gate 5
Email bounded-fetch shadow record](gate-5-email-fetch-shadow.md).

Bounded Email classification is accepted after synthetic API and launcher
checks, a consistent rollback snapshot, controlled live rule application,
rollback rehearsal, Playwright MCP verification, and Marc's normal-workflow
confirmation on 2026-10-07. Live `4276` retains Count/Fetch and enables only
local message tags, rule application, and rule management; OAuth and vault
export remain blocked. Legacy Email `4176` remains the production workflow for
export and the warm fallback. See [Gate 5 Email bounded-classification shadow
record](gate-5-email-classification-shadow.md).

Bounded Email OAuth is accepted after synthetic API and launcher checks,
immutable token backup, rollback rehearsal, Playwright MCP verification, and
Marc's normal Microsoft OAuth workflow confirmation on 2026-10-07. Live `4276`
retains Count/Fetch and classification and adds only interactive login and
reauthorization through `oauth.manage`; vault export remains blocked. Automatic
token refresh during an accepted fetch remains part of `mail.fetch`. Legacy
Email `4176` remains the production workflow for export and the warm fallback.
See [Gate 5 Email bounded-OAuth shadow record](gate-5-email-oauth-shadow.md).

Bounded Email export is implemented and verified with synthetic API, launcher,
rollback, regression, and Playwright MCP checks. It retains the accepted OAuth
profile and adds only `vault.export`. Preview is read-only, apply requires a
separate one-use plan, matching files are not rewritten, and differing targets
block the batch. The first live preview exposed the older flat archive schema
before any apply; it would have duplicated existing projections, so `4276` was
rolled back with the vault unchanged. The revised preview recognizes those
notes by account slug and timestamp, with bounded UID checks only for ambiguous
timestamps, and reports them separately without rewriting them. The optimized
profile is active on `4276`; a one-note pilot passed file, hash, database,
browser, and health verification. The remaining full preview contains 515 new,
one unchanged, 4,125 existing-archive, and zero conflicting notes and has not
been applied. Legacy Email `4176` remains the warm fallback. See [Gate 5 Email
bounded-export shadow record](gate-5-email-export-shadow.md).

Use the following sequence for each capability:

1. Confirm production is healthy.
2. Confirm candidate checks and rollback prerequisites.
3. Stop only the production component being migrated.
4. Take a consistent state backup when the component owns mutable local state.
5. Point only that capability at its intended live authority/state.
6. Start the candidate and run health, UI, read, persistence, and controlled
   write checks.
7. Use it through an ordinary workflow.
8. If acceptance fails, stop the candidate and restart the old component.

Recommended order: VaultGraph, monitoring, Homepage shell, Calendar reads,
project creation, Calendar writes, Email, then Beantime/Fava.

## Gate 6 - stable launcher switch

- Keep the legacy launcher available under an explicit name.
- Change the stable entry point only after every included capability has passed
  Gate 5.
- Verify aggregate startup, individual failure isolation, and shutdown.
- Rehearse switching the launcher back to the production checkout.

## Gate 7 - observation and retirement

- Use the new installation through at least one to two weeks of normal work.
- Keep the old checkout, configuration, databases, and launchers recoverable.
- Resolve issues in the new repository without moving authoritative vault data.
- Perform a final rollback rehearsal.
- Retire the old checkout only after explicit approval and a documented
  recovery test. Prefer archival/renaming before deletion.

## Capability acceptance checklist

A capability is accepted only when:

- [ ] startup and clean shutdown work;
- [ ] its health check succeeds;
- [ ] its UI works in the intended browser or Obsidian Webviewer;
- [ ] reads match the authoritative source;
- [ ] its intended controlled write succeeds, when applicable;
- [ ] restart preserves expected state;
- [ ] failures remain isolated;
- [ ] logs and audit output do not expose sensitive payloads;
- [ ] documentation and configuration examples are current;
- [ ] rollback completes within the agreed five-minute window;
- [ ] Marc confirms the normal workflow is usable.

## Decisions recorded at Gate 0

1. Preserve the useful source history through a sanitized import; do not import
   raw history.
2. Use a private `abhuva/nica-command-center` GitHub repository as the current
   remote copy. No second backup mechanism is required yet.
3. Track `Architecture Overview.canvas` and ignore local `.obsidian/` state.

## Decisions deferred to later gates

1. Choose the final secret-storage mechanism before any live credential moves;
   local runtime state currently defaults to `%LOCALAPPDATA%` through the
   candidate launcher.
2. Define the observation-period start and final retirement approval before
   Gate 7.
