# VaultGraph Task Tracker

## Gate 5 cutover

- status: technical cutover complete; normal-workflow confirmation pending
- owner: agent
- dependencies: [Gate 4 shadow verification]
- validation: synthetic smoke, component launcher rehearsal, Playwright at the
  daily VaultGraph URL, restart/persistence, and timed rollback

Implemented for cutover:

- Component-only plan/apply launcher on the existing port `4175`.
- Isolated state below `%LOCALAPPDATA%\NICA\CommandCenter\live\vaultgraph`.
- Exact-manifest stop path that does not stop unknown listeners.
- Rebuild opt-in writes only derived graph state, never vault content.
- Legacy rollback and return to the migrated server rehearsed on port `4175`.

Pending acceptance:

- Confirm the normal VaultGraph workflow is usable in Obsidian Webviewer.
- Homepage-tab integration remains part of the later Homepage cutover; the
  current Homepage configuration does not enable the VaultGraph module.

## v1 Folder Hierarchy Graph

- status: done
- owner: agent
- dependencies: []
- validation: `npm.cmd --prefix .\VaultGraph run check:smoke`

Implemented:

- Recursive folder hierarchy scanner.
- Generated graph JSON and browser JS payload.
- Local preview server on `127.0.0.1:4175`.
- Apache ECharts force graph UI.
- Depth, top-level folder, system-folder, and search filters.
- Render controls for labels, node scale, graph physics, line width, and color mode.
- View switcher for force graph and folder tree views.
- Treemap disk-usage view based on recursive folder file sizes.
- Node action panel for set-as-root, hide-subtree, and reset node filters.
- Relative-depth filtering based on the active root/focus.
- Rebuild endpoint and UI button.

Open items:

- status: todo
- owner: human/agent
- dependencies: [v1 folder hierarchy graph]
- validation: evaluate graph usability in Obsidian Webviewer

Potential next steps:

- Add note/file count metrics per folder.
- Add project MOC detection.
- Add Obsidian open-folder/open-note actions.
- Add persisted UI preferences.
