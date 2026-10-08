# ADR-007: Integrate the website console as an external service

**Status**: Accepted

**Date**: 2026-10-09

**Participants**: Marc Bielert and Codex-assisted implementation work

## Context

The independently owned `nica-website` repository provides a loopback-only
browser console for translation and deployment workflows. The console can edit
website source files, build generated output, compare a reviewed deployment
plan, and publish approved changes. It also owns its Python and Node
dependencies, local `.env` credentials, and plan-first safety checks.

The Command Center needs a shared entry point and optional workspace lifecycle
for this tool. Copying the console or proxying its action APIs would make the
Command Center partly responsible for public-website source and deployment,
contrary to the repository boundary in ADR-001 and the independent-service
launcher model in ADR-005.

## Decision

We decided to integrate the website console as an optional external workspace
service:

1. The machine-local workspace profile records the separate website repository
   path and console port. No website source, generated site, dependencies, or
   credentials are copied into this repository.
2. The Command Center starts the website repository's existing
   `tools/dev_console.ps1` contract and records only process ownership, logs,
   port, API version, and repository location in local state.
3. The website console exposes a read-only `GET /api/ping` identity contract.
   The Command Center uses it for health checks and refuses a normal stop while
   the console reports an active translation, build, check, or deployment.
4. The shared Home dashboard shows a `Website` entry only when
   `startup.services.websiteConsole` is enabled. It opens the console's
   `/translations` route in an Obsidian Web Viewer.
5. Translation and deployment requests continue to go directly from the
   console's own browser UI to its loopback server. The Command Center does not
   receive, store, log, or proxy the console mutation token or deployment
   credentials.
6. The static multilingual preview on port 8000 remains an on-demand website
   development command. It is not started automatically because its normal
   launcher performs a full build and writes generated output.

## Consequences

- (+) Users receive one shared Website entry and one-button optional startup.
- (+) Website deployment safety and credentials remain inside their owning
  repository.
- (+) Missing or failed website tooling does not make unrelated Command Center
  services unavailable.
- (+) Process manifests and the versioned health contract make repeated start
  and bounded stop behavior auditable.
- (-) Each workstation that enables the service needs a separate configured
  `nica-website` checkout with its own dependencies and local credentials.
- (-) Changes to the health or launcher contract require coordinated releases
  across two repositories.
- (=) Disabling the service affects the next workspace reconciliation; saving
  Settings does not interrupt a currently active website operation.
- (=) Website Preview may be added later as a separate on-demand capability if
  its build lifecycle warrants Command Center orchestration.

## Alternatives considered

### Copy the website console into the Command Center

Rejected because it would duplicate implementation and dependencies, blur
ownership of public website deployment, and create two places that must preserve
the same safety checks.

### Proxy website actions through the Homepage server

Rejected because the console already provides a loopback-bound token and
reviewed-plan workflow. A proxy would broaden the Homepage's authority and risk
exposing credentials or mutation capability outside the owning tool.

### Start both console and static preview on every workspace launch

Deferred because the preview command builds the complete multilingual site by
default. That work and generated output are unnecessary for users who only need
translation health or deployment status.
