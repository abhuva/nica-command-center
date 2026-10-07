# VaultGraph

> Migration candidate: set absolute `NICA_VAULT_ROOT` and `NICA_STATE_ROOT`
> values before running. Generated graph files and the PID file live below
> `NICA_STATE_ROOT\vaultgraph`; manual rebuild is disabled unless
> `NICA_WRITE_ENABLED=true`.

## Command-centre cutover launcher

From the command-centre repository root, preview the component-only live plan:

```powershell
.\scripts\start-vaultgraph.ps1 -VaultRoot "C:\path\to\vault"
```

After reviewing the authority, local state, port, and mode, start it on the
existing daily URL with rebuild enabled only for derived local state:

```powershell
.\scripts\start-vaultgraph.ps1 -VaultRoot "C:\path\to\vault" -EnableRebuild -Apply
```

Stop only the process recorded by this repository's manifest:

```powershell
.\scripts\stop-vaultgraph.ps1
```

The default state root is `%LOCALAPPDATA%\NICA\CommandCenter\live`, the default
port is `4175`, and the launcher never changes the vault or production
`startup-all.bat`. Omitting `-EnableRebuild` keeps the API read-only.

Local Obsidian/Webviewer tool for visualizing the vault folder hierarchy with Apache ECharts.

## Purpose

VaultGraph scans the folder hierarchy of the vault at full depth and renders it as an interactive graph. V1 is intentionally read-only: it does not move, rename, edit, or delete vault files.

## Files

- `build-graph.mjs`: scans the vault folder hierarchy and writes generated graph files.
- `graph.generated.json`: generated graph payload for the server/API.
- `graph.generated.js`: generated graph payload for direct browser loading.
- `serve.mjs`: local HTTP server and rebuild API.
- `stop-preview.mjs`: stops the preview server via PID file or legacy port detection.
- `vault-graph.html`: browser/Webviewer entry point.
- `vault-graph.css`: UI styling.
- `vault-graph.app.js`: ECharts rendering and filters.
- `smoke-check.mjs`: generated-data validation.

## Commands

Legacy commands from the former vault checkout:

```powershell
npm.cmd --prefix .\Tools\VaultGraph run build:graph
npm.cmd --prefix .\Tools\VaultGraph run preview
npm.cmd --prefix .\Tools\VaultGraph run stop:preview
npm.cmd --prefix .\Tools\VaultGraph run check:smoke
```

Commands from this repository use `--prefix .\VaultGraph` with explicit
`NICA_VAULT_ROOT` and `NICA_STATE_ROOT` values.

Open in Obsidian Webviewer:

```powershell
obsidian web url="http://127.0.0.1:4175/vault-graph.html"
```

Open in a browser:

```text
http://127.0.0.1:4175/vault-graph.html
```

## API

- `GET /api/ping`: health check.
- `GET /api/graph`: returns the current generated graph payload.
- `POST /api/graph/rebuild`: rescans the vault and rewrites generated graph files.

## Ignore Rules

The scanner excludes noisy or unsafe runtime folders:

- `.git`
- any `node_modules`
- `.obsidian/cache`
- `.obsidian/workspace*`
- generated preview PID/log files
- `.env` and `.env.*`

Symlinks are skipped to avoid recursive loops.

## UI

- Force-directed folder graph with pan/zoom.
- Tree view with polyline edges, based on the same filtered folder data.
- Treemap view for disk usage by folder, sized by recursive file bytes.
- Node size indicates descendant folder count.
- Node color indicates depth.
- Optional group color mode assigns colors to direct children of the current local root and shades descendants.
- Search filters paths by substring.
- Max-depth filter is relative to the current active root/focus.
- Top-level folder filter focuses one vault area.
- System-folder toggle hides or shows `.obsidian`, `Tools`, and hidden folders.
- Render controls include labels, node scale, force repulsion, edge length, gravity, friction, line width, tree spacing, and tree animation duration.
- Clicking a node opens side-panel actions to set it as root, hide its subtree, or reset node filters.

## Validation

For local changes:

```powershell
$env:NICA_VAULT_ROOT = "C:\path\to\synthetic-vault"
$env:NICA_STATE_ROOT = "C:\path\to\temporary-state"
npm.cmd --prefix .\VaultGraph run check:smoke
npm.cmd run lint
npm.cmd run lint:jsdoc
```

Do not use the live vault as an automated fixture. Browser-level verification
uses the installed Playwright MCP.
