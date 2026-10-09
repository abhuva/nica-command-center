# ADR-006: Separate shared dashboard services from personal bookmarks

**Status**: Accepted

**Date**: 2026-10-08

**Participants**: Marc Bielert and Codex-assisted implementation work

## Context

The Homepage exposes Obsidian bookmarks as a useful personal navigation view.
Bookmarks are not a reliable way to distribute the same operational entry
points to several users: their groups and items can differ, and a required
service may be missing or renamed on one workstation.

The command centre already has shared startup service choices for Calendar,
Email, VaultGraph, the external Website console, and the NICA and TOHU finance
services. Project and contact navigation also have stable shared Vault targets.
The Homepage needs a compact common entry view without taking ownership of
personal bookmark organization.

## Decision

1. The Homepage has a dedicated Dashboard module whose catalogue is defined by
   command-centre code, not by `.obsidian/bookmarks.json`.
2. Dashboard visibility follows the shared `startup.services` settings. The
   existing service choices cover Calendar, Email, Website, and both finance
   services; `projects` and `contacts` are shared navigation capabilities.
3. Calendar, Email, Website, and finance entries open their configured local
   service address in an Obsidian Web Viewer. Runtime ports come from the
   workspace profile through the Homepage launcher.
4. Projects and Contacts open only their fixed, allow-listed Vault targets:
   `6. Obsidian/Live/Projekte.md` and
   `6. Obsidian/Bases/Kontakte.base`.
5. Dashboard open requests are validated again by the server. Disabled and
   unknown entries are rejected, and browser payloads do not expose local URLs
   or Vault paths.
6. The Bookmarks module and its behavior remain independent and unchanged.

## Consequences

- (+) Every user receives the same operational entries from a versioned
  command-centre release.
- (+) Disabling a service removes its Dashboard entry as well as changing the
  next workspace reconciliation plan.
- (+) Personal bookmarks remain free for individual navigation and grouping.
- (+) Browser code cannot request arbitrary local paths or service URLs through
  the Dashboard endpoint.
- (-) Adding a new shared Dashboard destination requires a reviewed code and
  configuration change.
- (=) The Dashboard indicates desired service availability, while actual
  service health remains the responsibility of each component's health check.

## Alternatives considered

### Require a standard bookmark group

Rejected because it would still mix centrally deployed operational navigation
with user-owned bookmark state and require every user to maintain matching
bookmark identifiers.

### Allow arbitrary Dashboard links in browser settings

Rejected for the first version because it would broaden local path and URL
opening authority. The small fixed catalogue covers the current operational
need and keeps the server-side allow-list auditable.
