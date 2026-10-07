# Gate 5: project creation cutover

**Status:** technical cutover complete; awaiting normal-workflow acceptance

**Date:** 2026-10-07

**Branch:** `migration/project-creation-cutover`

The project-creation module will be added to the accepted migrated Homepage on
port `4274`. The legacy Homepage remains running on port `4174` as the normal
workflow and immediate fallback until the migrated workflow passes technical
verification and Marc confirms a real project creation.

## Boundaries

- The Nextcloud vault remains authoritative for project folders, MOC notes,
  project templates, naming conventions, and frontmatter.
- The migrated process receives the vault path and Obsidian vault name only at
  runtime. Neither is committed.
- The only newly enabled write capability is `project.create`.
  `NICA_WRITE_ENABLED` stays false, so settings, Bookmark/Search actions,
  Beantime, and monitor restart remain blocked.
- Apply requires `NICA_PROJECT_CREATE_ENABLED=true`, a current server-side plan
  identifier, and an ephemeral same-origin action token.
- Project titles and target paths are excluded from the local audit log. It
  records only outcome, plan prefix, year, society, and template identifier.

## Plan and apply behavior

The UI first submits a non-mutating project plan. The server validates the
year, society, project type, funding code, title, selected template, target
path, and collisions. It fingerprints the selected template and returns the
exact proposed folder, note, frontmatter, and confirmation identifier.

Apply recomputes the plan. Changed input, a changed template, a new collision,
or a missing confirmation is rejected. The note is prepared in a uniquely
named staging directory below `2. Projektverwaltung`, updated with canonical
frontmatter, and renamed to the final folder only after preparation succeeds.
An unsuccessful preparation removes only that exact staging directory. Failure
to open an already-created note in Obsidian is reported as a warning rather
than encouraging a duplicate retry.

## Start and rollback

Preview the first profile change while the accepted Homepage is still running:

```powershell
.\scripts\start-homepage.ps1 -VaultRoot "C:\path\to\vault" -ObsidianVaultName "vault-name" -PrepareProjectProfile
```

For cutover, stop only the migrated Homepage, prepare the profile, and start it:

```powershell
.\scripts\stop-homepage.ps1
.\scripts\start-homepage.ps1 -VaultRoot "C:\path\to\vault" -ObsidianVaultName "vault-name" -PrepareProjectProfile -Apply
```

Later starts omit `-PrepareProjectProfile`. Roll back to the accepted read-only
Homepage shell without changing the legacy process or vault content:

```powershell
.\scripts\stop-homepage.ps1
.\scripts\restore-homepage-shell-profile.ps1
.\scripts\restore-homepage-shell-profile.ps1 -Apply
.\scripts\start-homepage.ps1 -VaultRoot "C:\path\to\vault" -ObsidianVaultName "vault-name" -Apply
```

## Acceptance checklist

- [x] Synthetic plan/apply creates exactly one correctly named project and MOC.
- [x] Invalid input, stale plans, template changes, and collisions fail without
  leaving a staging or final project folder.
- [x] A simulated Obsidian failure removes its exact staging directory.
- [x] All unrelated POST routes remain HTTP 403.
- [x] The project profile retains Bookmarks, Clock, and monitoring behavior.
- [x] Playwright MCP verifies preview, explicit apply, responsive layout, and a
  clean browser console against a synthetic vault.
- [x] Live technical verification does not create a disposable society project.
- [x] Rollback to the accepted Homepage shell is rehearsed while legacy `4174`
  remains healthy.
- [ ] Marc creates one genuinely needed project through the normal Obsidian
  workflow and confirms the result.

## Technical verification evidence

- The synthetic HTTP workflow created exactly one project from a confirmed
  plan and verified its canonical frontmatter and absence of staging residue.
- Strict society/path validation, missing confirmation, changed-template,
  duplicate-target, disabled-capability, missing-token, and simulated Obsidian
  failures were exercised. The simulated post-staging failure cleaned up its
  exact temporary directory.
- The audit record excluded the synthetic title and project path.
- Playwright MCP completed the synthetic apply workflow, verified that changed
  form input disables Apply, found no horizontal overflow at 375 px, and found
  no fresh browser console warnings or errors.
- The live profile enables only Bookmarks, Clock, New Project, and Updo. Health
  reports `limited-write`, `projectCreate=true`, and `unrestricted=false`.
- Settings, Bookmark/Search actions, every Beantime action, monitor restart,
  and a project apply without the ephemeral token all returned HTTP 403.
- A live project preview returned a valid plan but created no final or staging
  folder. Playwright verified the same preview/invalidation flow without
  pressing the final create button.
- Rollback restored the accepted read-only Homepage profile on `4274`, kept
  legacy `4174` healthy, and the project profile was then reapplied successfully.
- The first user apply exposed an unawaited Obsidian folder-creation call. Its
  exact staging folder was removed and no final project remained. The handoff
  now awaits Obsidian folder creation, template rendering, rename, and cleanup
  through Obsidian's vault API before reporting completion.
- A second user apply exposed the remaining cause: Obsidian excludes
  dot-prefixed folders from its vault index. Staging now uses the indexed
  `_nica-project-staging-*` prefix while retaining exact-path cleanup. A bounded
  live probe confirmed that Obsidian could create, discover, and remove that
  prefix, with no filesystem residue.
