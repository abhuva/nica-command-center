# Gate 5: VaultGraph cutover

**Status:** technical cutover complete; normal-workflow confirmation pending

**Date:** 2026-10-06

**Branch:** `migration/vaultgraph-cutover`

VaultGraph is the first Gate 5 capability. The migrated implementation now
serves the existing daily URL at
`http://127.0.0.1:4175/vault-graph.html`. The former vault checkout remains in
place as the immediate rollback implementation.

## Boundaries and safety

- The NICA vault remains the authoritative folder hierarchy.
- Generated graph files, logs, PID data, and the cutover manifest live below
  `%LOCALAPPDATA%\NICA\CommandCenter\live\vaultgraph`.
- Rebuild writes only replaceable derived graph state. It does not modify vault
  content.
- No credentials were needed, copied, logged, or committed.
- `startup-all.bat` and the other production capabilities were not changed.
- The launcher refuses an occupied port and does not stop an unknown process.
- Stop uses the exact process recorded in this repository's manifest and
  verifies its command line before terminating it.

## Cutover procedure

The plan is inspectable without changing runtime state:

```powershell
.\scripts\start-vaultgraph.ps1 -VaultRoot "C:\path\to\vault" -EnableRebuild
```

Apply and stop are separate operations:

```powershell
.\scripts\start-vaultgraph.ps1 -VaultRoot "C:\path\to\vault" -EnableRebuild -Apply
.\scripts\stop-vaultgraph.ps1
```

The live apply indexed 1,447 folders and 1,446 edges with two ignored paths and
zero scan errors. Restart produced the same folder and edge counts.

## Verification evidence

- Synthetic smoke and isolated-state launcher tests passed.
- Plan-only mode created no listener.
- Read-only versus rebuild-enabled health modes reported the expected authority,
  state path, and write status.
- A negative test against occupied port `4174` failed without stopping or
  disturbing Homepage.
- Playwright MCP verified the migrated UI at 375 px width with no horizontal
  overflow. Graph, Tree, and Treemap views rendered, the migration marker was
  present, and the final console contained no errors.
- Playwright triggered a rebuild; `POST /api/graph/rebuild` returned HTTP 200
  and the UI returned to `Ready: 1447 folders`.
- Stop/restart preserved the derived graph and reproduced 1,447 folders, 1,446
  edges, and zero scan errors.
- Calendar, Homepage, and Email remained healthy on ports `4173`, `4174`, and
  `4176` during the component-only cutover.
- Gitleaks scanned the pending changes and all reachable history with no
  findings before commit.

The current Homepage local configuration does not enable its VaultGraph tab.
Direct use on port `4175` is therefore the verified daily endpoint. Enabling
the Homepage integration belongs to the later Homepage capability cutover.

## Rehearsed rollback

Rollback from the migrated server to the legacy implementation was rehearsed:

```powershell
.\scripts\stop-vaultgraph.ps1
npm.cmd --prefix .\Tools\VaultGraph run preview
```

The legacy implementation rebuilt the same 1,447-folder graph and served the
same port. Playwright verified its Graph UI at 375 px without horizontal
overflow and confirmed that it did not carry the migration marker. The legacy
server was started in a managed foreground terminal and stopped with
`Ctrl+C`; its legacy `stop:preview` PID check did not recognize the npm-managed
process, so that command is not the rollback-session shutdown procedure.

The migrated server was then restored with its component launcher. Active
command time for either direction was well within the five-minute rollback
objective; user-response pauses were not counted.

## Remaining acceptance

The technical acceptance checks pass. The source checkout is retained and
must not be retired. VaultGraph is accepted only after Marc confirms that the
normal workflow is usable in Obsidian Webviewer. Until then, rollback remains
the two-command procedure above.
