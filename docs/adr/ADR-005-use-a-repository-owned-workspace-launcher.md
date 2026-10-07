# ADR-005: Use a repository-owned workspace launcher

**Status**: Accepted

**Date**: 2026-10-08

**Participants**: Marc Bielert and Codex-assisted migration work

## Context

The vault-local `startup-all.bat` is the current one-button entry point for the
daily workspace. It opens Obsidian and starts Calendar, Homepage, Email, and two
finance servers in separate visible terminal windows. It assumes that the
software checkout is the vault's `Tools` child and therefore prevents retiring
that checkout even though the individual migrated capabilities are accepted.

The tools have useful process boundaries: Calendar, Email, VaultGraph, and Fava
have different dependencies and failure modes. Combining them into one server
would reduce visible processes but would also couple their availability. The
operator instead needs a cleaner one-button experience, bounded process
ownership, and the ability to omit unused services on the next startup.

This decision builds on [ADR-001](ADR-001-separate-operational-software-from-the-shared-vault.md),
[ADR-002](ADR-002-explicit-vault-and-local-state-roots.md), and
[ADR-003](ADR-003-use-operation-specific-capability-interlocks.md).

## Decision

We decided to provide a repository-owned, short-lived workspace launcher that:

1. reads machine-local authority and port configuration below
   `NICA_STATE_ROOT`;
2. reads non-secret startup choices from Homepage local settings;
3. reconciles independently owned background services instead of hosting them
   in one monolithic process;
4. starts services without persistent terminal windows and retains separate
   manifests and logs;
5. leaves a healthy repository-owned process running when startup is invoked
   repeatedly;
6. isolates failures, records an aggregate result, and continues starting
   unrelated selected services;
7. opens the explicitly configured Obsidian vault and selected workspace views;
8. provides a matching aggregate stop operation that validates ownership before
   stopping processes.

Homepage remains the required control surface. Calendar, Email, VaultGraph,
NICA Fava, and TOHU Fava are independently selectable for the next startup.
Homepage module visibility remains separate from service selection. Monitoring
and on-demand Beantime Fava remain children of Homepage rather than becoming
additional top-level services.

Homepage may expose a bounded `settings.manage` capability that writes only its
local normalized settings file below `NICA_STATE_ROOT`. It does not authorize
vault, ledger, calendar, email, or remote-service writes.

Authoritative Beantime ledger data remains in the Nextcloud vault but must move
to a vault-owned location outside the retiring `Tools` checkout. The source
ledger is retained as rollback material until observation and retirement are
complete.

## Alternatives considered

### Keep the visible batch-file terminals

This preserves the current implementation with little work. It was rejected
because terminal lifetime is being used as process supervision, diagnostics are
fragmented, and the launcher remains coupled to `<vault>/Tools`.

### Merge every tool into Homepage

This would produce one process and one terminal. It was rejected because an
Email or Calendar failure could then make the operational shell unavailable,
and the tools would lose their useful independent lifecycle.

### Install Windows services or a permanent supervisor

This could provide automatic boot startup and continuous reconciliation. It was
deferred because the present requirement is an explicit one-button daily
workspace, not an always-on server installation.

### Use module visibility as the service-start switch

This would avoid a second set of toggles. It was rejected because showing a
Homepage card and consuming resources in a background service are different
operator choices.

## Consequences

- (+) One action opens a complete workspace without persistent terminal windows.
- (+) Unused services can remain stopped on the next launch.
- (+) Independent process and data boundaries remain intact.
- (+) Repeated startup and aggregate shutdown can validate exact ownership.
- (+) Startup failures become visible through one aggregate status record.
- (-) The launcher must understand the stable contracts of each component.
- (-) Homepage local settings become an input to startup and therefore require
  backward-compatible schema handling.
- (-) Machine-local setup is required once for the vault name, vault root,
  ports, and finance ledger locations.
- (=) Disabling a service affects the next reconciliation; it does not silently
  terminate a currently running workflow when Settings is saved.
- (=) Individual services continue to use multiple background processes even
  though the user no longer sees multiple terminal windows.
