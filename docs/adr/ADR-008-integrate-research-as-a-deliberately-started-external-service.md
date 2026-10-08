# ADR-008: Integrate research as a deliberately started external service

**Status**: Accepted

**Date**: 2026-10-09

**Participants**: Marc Bielert and Codex-assisted implementation work

## Context

The independently owned `research-agent` repository provides the Funding
Observatory: a loopback FastAPI dashboard, private SQLite state, editable
society profiles, preserved source material, and a serialized Codex research
worker. Starting its browser host also starts that worker. Existing queued or
scheduled work can therefore resume and consume account quota without another
button press.

The Command Center needs a shared Research entry and an optional local
lifecycle without acquiring research data, credentials, scheduling policy or
worker control. The website-console integration in ADR-007 provides a useful
external-service boundary, but research startup is more consequential and must
not be inferred merely from dashboard visibility.

## Decision

We decided to integrate the Funding Observatory as a separately owned,
deliberately started external service:

1. The machine-local workspace profile records the research repository, its
   private data directory and loopback port. No research database, profiles,
   sources, results or credentials are copied into this repository.
2. Dashboard visibility is controlled by
   `modules.dashboard.services.researchAgent`. Automatic workspace startup is
   a separate `startup.services.researchAgent` choice and defaults to false.
3. Clicking the Research entry is an explicit start-or-open action. Starting
   uses the research repository's installed `funding-agent serve` contract and
   may resume queued work; the Settings UI states that consequence.
4. The Funding Observatory exposes version 1 of a minimal `GET /api/ping`
   contract containing only identity, backend, pause/busy state and worker
   state. The Command Center does not call or proxy its research APIs.
5. The Command Center records only process ownership, local configuration,
   logs and health-contract metadata. It opens the dashboard directly in an
   Obsidian Web Viewer.
6. Normal aggregate shutdown stops only an idle process owned by the Command
   Center. If `busy` is true, shutdown refuses to terminate it and tells the
   operator to pause new work and wait for or cancel the active run.
7. When auto-start is disabled, workspace startup leaves an already running
   research process alone. This preserves the distinction between visibility,
   deliberate manual start and automatic scheduling.

## Consequences

- (+) All users can receive the same Research entry without personal bookmarks.
- (+) Expensive background work cannot be enabled accidentally by showing the
  entry on the Dashboard.
- (+) Research data, prompts, evidence and credentials remain in their owning
  repository and private data directory.
- (+) Versioned health and exact process manifests support bounded local
  supervision without exposing private state.
- (-) Each managed workstation needs a configured research checkout, installed
  virtual environment and private data directory.
- (-) Health-contract changes require coordinated releases across two
  repositories.
- (-) Aggregate shutdown can report a deliberate failure while research is
  active; the operator must resolve that work before a safe stop.
- (=) A future remotely hosted or Raspberry Pi instance can use the same direct
  dashboard link while process management is disabled locally.

## Alternatives considered

### Couple Dashboard visibility to automatic startup

Rejected because simply distributing a shared navigation entry would then be
enough to resume queued work and consume quota.

### Proxy research controls and data through Homepage

Rejected because it would broaden Homepage authority, duplicate the research
agent's CSRF boundary and risk exposing sensitive profiles, evidence or results.

### Force-stop the worker during aggregate shutdown

Rejected because an active Codex subprocess or evidence-preservation phase may
be interrupted. The owning dashboard already provides pause and cancellation
controls with domain-specific recovery semantics.

### Move the research database below Command Center state

Rejected because the database and profiles belong to the Funding Observatory.
The Command Center records only the configured path and never becomes their
source of truth.
