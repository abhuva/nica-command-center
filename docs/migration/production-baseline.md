# Production baseline snapshot

**Observed**: 2026-10-06

**Purpose**: Record a non-invasive point-in-time baseline for the working vault
tools. This is not a promise that every optional service is always running.

No service was started, stopped, or reconfigured while taking this snapshot.
Machine-specific executable paths and process IDs are intentionally omitted.

## Core runtimes

| Runtime | Observed version/status |
| --- | --- |
| Node.js | `v23.6.1` |
| npm | `10.9.2` |
| Python | `3.13.2` |
| Git | `2.49.0.windows.1` |
| Obsidian CLI | Available; authoritative application/CLI version still to record |
| Fava | Available; package version still to record |
| updo | Available; version still to record |
| Docling | Available; package version still to record |

## Service snapshot

| Capability | Production endpoint | Snapshot result |
| --- | --- | --- |
| Calendar | `127.0.0.1:4173/api/ping` | HTTP 200; Node.js listener on loopback |
| Homepage | `127.0.0.1:4174/api/ping` | HTTP 200; Node.js listener on loopback |
| VaultGraph | `127.0.0.1:4175/api/ping` | Not running during snapshot |
| Email | `127.0.0.1:4176/api/ping` | HTTP 200; Python listener on loopback |
| Beantime Fava | `127.0.0.1:3464` | Not running during snapshot |
| NICA Fava | `127.0.0.1:4998` | HTTP 200; Python listener on loopback |
| TOHU Fava | `127.0.0.1:4999` | HTTP 200; Python listener on loopback |

VaultGraph and Beantime Fava being stopped is not by itself a fault: both are
started on demand in current workflows. Their documented startup and health
checks still require verification before their respective cutovers.

## Source validation already observed

- Root ESLint check passed with the current uncommitted source work.
- Root JSDoc lint check passed.
- Email smoke check passed using a temporary database/export directory.
- Calendar and VaultGraph smoke checks were not run during inventory because
  their current commands rebuild output from the live vault.

## Baseline still to capture before Gate 1 exits

- Exact Fava, Docling, updo, and authoritative Obsidian CLI versions
- A normal-workflow startup check using the existing launchers at an agreed
  low-impact time
- Current configuration file existence and ownership without recording values
- State-aware Email database backup and restore evidence
- Normal daily workflow checks supplied or confirmed by Marc
