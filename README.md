# Homepage Tool (Modular)

Lokaler Preview-Server fuer eine modulare Obsidian-Homepage.

## Migration candidate

This checkout is the isolated migration candidate, not the current production
installation. It requires explicit `NICA_VAULT_ROOT` and `NICA_STATE_ROOT`
values, uses separate candidate ports, and rejects action endpoints unless
`NICA_WRITE_ENABLED=true` is deliberately set. Preview the startup plan with:

```powershell
.\scripts\start-candidate.ps1 -VaultRoot "C:\path\to\vault"
```

Add `-Apply` only after reviewing the plan. See
[`docs/migration/gate-3-candidate-runtime.md`](docs/migration/gate-3-candidate-runtime.md)
for checks and shutdown instructions. The older `Tools/...` commands below
describe the still-running production layout and are retained as migration
reference until capability cutover.

Obsidian CLI reads require an explicit `OBSIDIAN_VAULT_NAME`; they never fall
back to whichever vault happens to be active. Obsidian UI actions additionally
require `NICA_OBSIDIAN_ACTIONS_ENABLED=true`. Filesystem-only project creation,
Calendar fixture fallback, monitoring, and local state workflows do not need
Obsidian actions enabled.

### Gate 5 Homepage shell launcher

The migrated read-only shell combines Bookmarks, Clock, and the accepted
website monitor on port `4274`. Preview the first profile change before
applying it:

```powershell
.\scripts\start-homepage.ps1 -VaultRoot "C:\path\to\vault" -ObsidianVaultName "vault-name" -PrepareShellProfile
.\scripts\start-homepage.ps1 -VaultRoot "C:\path\to\vault" -ObsidianVaultName "vault-name" -PrepareShellProfile -Apply
```

Later starts omit `-PrepareShellProfile`. Open the shell in Obsidian with:

```powershell
obsidian web url="http://127.0.0.1:4274/home.html?module=bookmarks"
```

Stop only the migrated shell while retaining its local settings and monitoring
history:

```powershell
.\scripts\stop-homepage.ps1
```

To restore the monitoring-only profile, stop the shell and run:

```powershell
.\scripts\restore-monitoring-profile.ps1
.\scripts\restore-monitoring-profile.ps1 -Apply
.\scripts\start-monitoring.ps1 -VaultRoot "C:\path\to\vault" -Apply
```

The legacy Homepage remains available on port `4174`. Use it for New Project
and Beantime until those capabilities complete their own cutovers.

### Gate 5 project-creation launcher

Project creation is enabled as a narrowly scoped addition to the migrated
Homepage. Preview the profile transition first:

```powershell
.\scripts\start-homepage.ps1 -VaultRoot "C:\path\to\vault" -ObsidianVaultName "vault-name" -PrepareProjectProfile
```

After stopping only the migrated Homepage, apply it once with
`-PrepareProjectProfile -Apply`. Later starts use the retained profile and only
`-Apply`. The UI requires a successful server preview before its separate
create action becomes available. Other Homepage POST actions remain disabled.

To restore the accepted read-only shell, stop the migrated Homepage, preview
and apply `scripts/restore-homepage-shell-profile.ps1`, then start the Homepage
normally. The legacy Homepage on `4174` remains available throughout.

### Gate 5 monitoring launcher

Website monitoring can run independently from the Homepage cutover. Preview
the component plan from this repository:

```powershell
.\scripts\start-monitoring.ps1 -VaultRoot "C:\path\to\vault" -InitializeFromLegacy
```

For the first start, review the plan and add `-Apply`. The initialization takes
a validated snapshot of only the legacy `updo` settings and derived history;
it does not change or stop the legacy Homepage. Later starts omit
`-InitializeFromLegacy`:

```powershell
.\scripts\start-monitoring.ps1 -VaultRoot "C:\path\to\vault" -Apply
```

Open the monitoring-only candidate directly:

```text
http://127.0.0.1:4274/home.html?module=updo
```

Stop only the migrated monitoring process while retaining its local history:

```powershell
.\scripts\stop-monitoring.ps1
```

The legacy Homepage on port `4174` remains available as warm rollback during
the observation period. Both processes perform read-only `HEAD` probes while
they run; their derived histories are stored separately.

### Gate 5 Calendar read launcher

The migrated Calendar reader runs beside the legacy Calendar on port `4273`.
Its first start prepares a local read-only credential profile containing only
the Google API-key and Nextcloud CalDAV values required for reads:

```powershell
.\scripts\start-calendar-read.ps1 -VaultRoot "C:\path\to\vault" -ObsidianVaultName "vault-name" -InitializeReadProfile
.\scripts\start-calendar-read.ps1 -VaultRoot "C:\path\to\vault" -ObsidianVaultName "vault-name" -InitializeReadProfile -Apply
```

Later starts omit `-InitializeReadProfile`. Open it in Obsidian with:

```powershell
obsidian web url="http://127.0.0.1:4273/cal.html"
```

Stop only the migrated reader while retaining its filtered local profile and
derived event bundle:

```powershell
.\scripts\stop-calendar-read.ps1
```

OAuth credentials/tokens, remote create targets, and SFTP publishing
credentials are intentionally not copied. Refresh, publishing, OAuth changes,
event creation, and event editing remain disabled. The legacy Calendar stays
available on port `4173` as warm rollback.

### Gate 5 Calendar vault-event creation

The accepted Calendar runtime reuses the read profile and enables only
confirmed Markdown event-note creation. Preview the runtime authority with:

```powershell
.\scripts\start-calendar-vault-write.ps1 -VaultRoot "C:\path\to\vault" -ObsidianVaultName "vault-name"
```

For a controlled cutover, stop the migrated reader and start the narrow writer:

```powershell
.\scripts\stop-calendar-read.ps1
.\scripts\start-calendar-vault-write.ps1 -VaultRoot "C:\path\to\vault" -ObsidianVaultName "vault-name" -Apply
```

Google, CalDAV, OAuth, event editing, rebuild, Obsidian actions, and publishing
remain disabled. Roll back by stopping the process and starting
`start-calendar-read.ps1` again. Legacy Calendar `4173` remains the fallback.

### Gate 5 Email read-only shadow

Email migration starts with a consistent snapshot of the live WAL-backed
SQLite database. The candidate runs on `4276` without copying mail credentials
or OAuth tokens, and every POST action remains disabled:

```powershell
.\scripts\start-email-read.ps1 -VaultRoot "C:\path\to\vault" -RefreshSnapshot
.\scripts\start-email-read.ps1 -VaultRoot "C:\path\to\vault" -RefreshSnapshot -Apply
```

Legacy Email `4176` remains the production workflow. Stop only the shadow with
`.\scripts\stop-email-read.ps1`.

### Gate 5 Email bounded-fetch shadow

The next slice allows only IMAP count and fetch into the candidate's isolated
snapshot. Preview the profile and snapshot preparation first:

```powershell
.\scripts\start-email-fetch-shadow.ps1 -VaultRoot "C:\path\to\vault" -PrepareFetchProfile -RefreshSnapshot
```

After review, stop only migrated `4276` and apply the bounded profile with the
same command plus `-Apply`. OAuth setup, classification, rules, tags, and vault
export remain disabled; legacy Email `4176` remains the production workflow.

### Gate 5 Email bounded-classification shadow

The next Email slice retains Count/Fetch and enables only local rule management,
rule application, and message tagging in the isolated candidate database.
Preview the activation and consistent rollback snapshot first:

```powershell
.\scripts\start-email-classification-shadow.ps1 -VaultRoot "C:\path\to\vault" -BackupCandidate
```

After review, stop only migrated `4276` and repeat the command with `-Apply`.
OAuth setup and vault export remain disabled. Roll back by stopping the
classification profile and starting `start-email-fetch-shadow.ps1` without a
snapshot refresh. Repeating `-BackupCandidate` retains an existing recovery
copy; `-RefreshCandidateBackup` is required to replace it and preserves the
original first. Legacy Email `4176` remains available throughout.

### Gate 5 Email bounded-OAuth shadow

The OAuth slice retains Count/Fetch and classification and adds only interactive
Microsoft login and reauthorization. Preview the activation and immutable local
token backup first:

```powershell
.\scripts\start-email-oauth-shadow.ps1 -VaultRoot "C:\path\to\vault"
```

After review, stop only migrated `4276` and repeat the command with `-Apply`.
The callback remains loopback-only on port `8080` by default, existing recovery
copies are retained, and vault export remains disabled. Roll back by stopping
the OAuth profile and starting `start-email-classification-shadow.ps1 -Apply`.
Legacy Email `4176` remains available throughout.

### Gate 5 Email bounded-export shadow

The export slice retains Count/Fetch, classification, and OAuth and adds only
`vault.export`. Preview the runtime transition first:

```powershell
.\scripts\start-email-export-shadow.ps1 -VaultRoot "C:\path\to\vault"
```

After review, stop only migrated `4276` and repeat the command with `-Apply`.
Activation does not export automatically: **Preview Export** performs a
read-only aggregate plan, and **Apply Export** is a separate action using a
one-use token. Matching files are left untouched and differing target files
block apply. Roll back by stopping the export profile and starting
`start-email-oauth-shadow.ps1 -Apply`. Legacy Email `4176` remains available
throughout. Live activation is still pending.

## Ziele

- Homepage in Obsidian Webviewer ueber lokalen Server.
- Module koennen per Settings ein/ausgeschaltet werden.
- Lokale, einfache Konfiguration in `Tools/config/`.
- Klick auf Bookmark-Karten nutzt native Obsidian-Bookmark-Logik (`openBookmark`).

## Ordnerstruktur

- `Tools/home.html`: Hauptseite (Layout + CSS + Script-Einbindung).
- `Tools/app/homepage.css`: Styles fuer die Homepage.
- `Tools/app/homepage.js`: Bootstrap + Modul-Registry.
- `Tools/modules/bookmarks.js`: Bookmarks-Modul.
- `Tools/modules/clock.js`: Uhrzeit-Modul.
- `Tools/modules/beantime.js`: Beancount-basiertes Start/Stop-Zeiterfassungs-Modul.
- `Tools/modules/email.js`: Email-DB-Modul als eingebettetes lokales Tool.
- `Tools/settings.html`: Settings-Seite (UI fuer Konfiguration).
- `Tools/serve.mjs`: HTTP-Server + API.
- `Tools/stop-preview.mjs`: stoppt den Preview-Server auf Port `4174`.
- `Tools/config/settings.default.json`: versionierte Default-Konfiguration.
- `Tools/config/settings.local.json`: lokale Ueberschreibungen fuer diesen Arbeitsplatz.

## Start / Stop

Von Repository-Root:

```powershell
npm.cmd --prefix .\Tools run preview
```

Alle lokalen Tools plus Obsidian-Homepage starten:

```powershell
.\startup-all.bat
```

Hinweis: `startup-all.bat` liegt eine Ebene ueber diesem Repository und wird ausserhalb von Git gepflegt. Falls der Sammelstarter nicht vorhanden ist, starte die Homepage lokal mit:

```powershell
npm.cmd --prefix .\Tools run preview
```

Der Sammelstarter startet Homepage, Calendar, VaultGraph sowie die beiden Fava-Server fuer NICA/TOHU in eigenen Terminalfenstern und oeffnet danach `http://127.0.0.1:4174/home.html` in Obsidian.
Wenn der externe Sammelstarter aktuell ist, startet er zusaetzlich den Email-Preview-Server auf `http://127.0.0.1:4176/email.html`.

Voraussetzung fuer Website Monitoring (`updo`-Modul): Das `updo` CLI muss installiert und im `PATH` verfuegbar sein.

Stoppen:

```powershell
npm.cmd --prefix .\Tools run stop:preview
```

## Quality Checks (JS/MJS)

Von Repository-Root:

```powershell
npm.cmd --prefix .\Tools run lint
npm.cmd --prefix .\Tools run lint:jsdoc
```

Hinweis: JSDoc-Regeln sind als Fehler geschaltet. Fehlende oder unvollstaendige JSDoc-Kommentare lassen `lint` fehlschlagen.

Direkt im Obsidian Webviewer oeffnen:

```powershell
obsidian web url="http://127.0.0.1:4174/home.html"
```

Settings-Seite:

```powershell
obsidian web url="http://127.0.0.1:4174/settings.html"
```

## API

- `GET /api/ping`: Health-Check.
- `GET /api/settings`: Effektive Settings (Default + Local Merge).
- `POST /api/settings`: Speichert Settings nach `Tools/config/settings.local.json`.
- `GET /api/bookmarks`: Liest `.obsidian/bookmarks.json` fuer Bookmark-Modul.
- `POST /api/bookmarks/open`: Oeffnet Bookmark in Obsidian ueber Bookmark-Plugin-API.
- `GET /api/obsidian/theme`: Liefert einen Theme-Snapshot aus Obsidian (fuer `mirror-obsidian`).
- `POST /api/search/open`: Oeffnet konfigurierte Header-Suche in Obsidian.
- `GET /api/projects/meta`: Liefert Vorschlagswerte fuer neue Projekte (Year/Society/Type/Foerderkuerzel) und verfuegbare Projekt-Templates.
- `POST /api/projects/create`: Erstellt neuen Projektordner + MOC-Datei per ausgewaehltem Projekt-Template und oeffnet die Datei.
- `GET /api/updo/snapshot`: Liefert Monitoring-Snapshot fuer das `updo`-Modul.
- `GET /api/updo/history`: Liefert komprimierte Langzeitdaten + Incident-Liste (`rangeDays` optional).
  - Enthält bei TLS-Fehlern ein `sslIssue`-Objekt (z. B. `ERR_TLS_CERT_ALTNAME_INVALID`).
- `POST /api/updo/restart`: Startet den `updo`-Monitorprozess neu.
- `GET /api/beantime/meta`: Liefert laufenden Beantime-Timer + buchbare Beancount-Konten + Personenkonten (`Zeit:*`).
- `POST /api/beantime/start`: Startet Beantime-Timer (nur State-Datei, noch keine Ledger-Buchung).
- `POST /api/beantime/stop`: Stoppt Timer, berechnet Dauer und schreibt Beancount-Transaktion.
- `POST /api/beantime/show`: Startet (falls noetig) einen Fava-Server auf `127.0.0.1:3464` und oeffnet ihn im Obsidian-Webviewer.

## Konfigurationsprinzip

1. Defaults aus `settings.default.json`.
2. Lokale Ueberschreibung aus `settings.local.json`.
3. Server liefert die gemergten, validierten Settings aus.

Damit sind spaetere Features stabil erweiterbar (neue Module, neue Optionen).

## Aktuelle Module

- Homepage-Layout:
  - Aktivierte Module erscheinen als Icon-Tabs im Header.
  - Es wird jeweils genau ein Modul-Panel unterhalb des Headers gerendert (Tab-Prinzip statt gestapelter Boxen).
  - Die zuletzt aktive Modul-Auswahl wird lokal gespeichert (`homepage-active-module-v1`).
- `bookmarks`: Visuelle Bookmark-Navigation.
  - Optional: Pfadanzeige (`showPath`) an/aus.
  - Optional: Typ-Badge (`showType`) an/aus.
  - Optional: Oeffnen in neuem Tab (`openInNewTab`) an/aus.
  - Optional: Kartenbreite (`cardMaxWidth`, 205-420 px).
- `clock` (Uhrzeit): Live-Digitaluhr im Header/Banner.
- `newProject` (Neues Projekt erstellen): Dialog fuer neue Projekte in `2. Projektverwaltung` inkl. Template-Auswahl und Naming-Validierung.
  - Projekt-Templates werden aus `6. Obsidian/_template/project/*.md` geladen.
  - Angezeigt werden die Dateinamen ohne `.md`; `Projekt.md` steht standardmaessig oben, falls vorhanden.
- `beantime` (Beancount): Start/Stop-Timer mit Konten- und Personenauswahl; schreibt beim Stop eine fertige `HR`-Buchung inkl. Metadaten in eine Beancount-Datei.
  - Standard-Ziel fuer Laufzeitbuchungen: `Tools/data/beantime/zeit.beancount` (lokal, git-ignored).
  - Vorlage fuer Kontenstruktur: `Tools/beantime/zeit.beancount` (Repository-Template).
  - Enthaelt den Button `Show`, der Fava auf Port `3464` oeffnet.
- `vaultGraph`: Bindet die separate VaultGraph-Preview (`http://127.0.0.1:4175/vault-graph.html`) als Homepage-Tab ein.
  - Voraussetzung: `npm.cmd --prefix .\Tools\VaultGraph run preview` laeuft.
- `email`: Bindet die separate Email-DB-Preview (`http://127.0.0.1:4176/email.html`) als Homepage-Tab ein.
  - Voraussetzung: `npm.cmd --prefix .\Tools\Email run preview` laeuft.
  - Workflow: IMAP-Abruf nach Datum/UID in SQLite, Klassifizierung/Regeln in der Datenbank, Export eines gefilterten Subsets nach `8. Emails`.
- `updo` (Website Monitoring): Statuskarten + Latenz/Verfuegbarkeits-Charts fuer konfigurierten URL-Satz.
  - Live-Ansicht: 15m / 1h / 6h aus In-Memory-Ringpuffer.
  - Langzeit-Ansicht: 7d / 30d / 90d aus komprimierten Persistenzdaten.
  - Persistenzdateien (lokal): `Tools/data/updo/raw.jsonl`, `Tools/data/updo/longterm.jsonl`, `Tools/data/updo/incidents.jsonl`, `Tools/data/updo/state.json`.
  - Kompression wird ausgeloest bei Punkteschwelle (`compressCount`) oder Zeitspanne (`compressSpanMinutes`) und behaelt einen konfigurierbaren Live-Tail (`keepTailPoints`).
  - Kennzeichnet Zertifikatsprobleme explizit (z. B. `SSL MISMATCH`) statt nur generisch `DOWN`.

## Projektnaming-Doku

- Regeln fuer Projektnamen und Frontmatter: `Tools/docs/project-naming-and-creation.md`

## UI-Theming (Homepage + Settings)

- Theme-Modus:
  - `preset`: Nutzt lokale Theme-Presets.
  - `mirror-obsidian`: Liest Obsidian-Theme-Werte ueber Server-Endpoint und mapped sie auf Tool-Tokens.
- Presets: `soft`, `flat`, `high-contrast`.
- Shape-Profile: `rounded`, `comfortable`, `sharp`.
- Gilt fuer beide Seiten: `home.html` und `settings.html`.

### Theme-Settings (Schema)

UI-Optionen liegen unter `ui` in den Settings:

```json
{
  "ui": {
    "title": "Workspace Homepage",
    "titleSize": 38,
    "search": {
      "provider": "omnisearch",
      "openInNewTab": false
    },
    "theme": {
      "mode": "preset",
      "preset": "soft",
      "shape": "rounded"
    }
  }
}
```

### Mirror-Mechanik

1. Frontend fragt `GET /api/obsidian/theme`.
2. Server liest Theme-Werte via `obsidian eval` aus Obsidian (`document.body` CSS-Variablen).
3. Frontend mapped Werte auf lokale CSS-Tokens.
4. Falls Theme-Daten fehlen/fehlschlagen: automatischer Fallback auf `preset`.

### First-Paint Verhalten (kein Theme-Flash)

- Beide Seiten nutzen einen lokalen Bootstrap-Cache in `localStorage`:
  - Key: `homepage-theme-bootstrap-v1`
- Ziel: Theme-Daten vor dem ersten Paint anwenden, bevor async API-Requests zurueck sind.
- Ergebnis: Kein sichtbarer Wechsel von Default-Theme auf Ziel-Theme beim Reload/Seitenwechsel (nach erstem erfolgreichen Load).

### Troubleshooting

- Mirror ohne Effekt:
  - `http://127.0.0.1:4174/api/obsidian/theme` pruefen (es muessen `vars` mit Werten kommen).
  - Preview-Server neu starten (`stop:preview` + `preview`), falls neue API-Routen noch nicht aktiv sind.
- Unerwartete Restfarben nach Refactor:
  - `localStorage`-Eintrag `homepage-theme-bootstrap-v1` loeschen und Seite neu laden.

## Recent Changes

- Homepage-Module von gestapelten, einklappbaren Boxen auf Header-Icon-Tabs umgestellt (ein aktives Modul zur Zeit).
- Aktive Modulwahl wird lokal gespeichert (`homepage-active-module-v1`) und beim Laden wiederhergestellt.
- Modulares Theme-System eingefuehrt (`ui.theme.mode/preset/shape`).
- Presets hinzugefuegt: `soft`, `flat`, `high-contrast`.
- Shape-Profile hinzugefuegt: `rounded`, `comfortable`, `sharp`.
- Obsidian-Mirror-Modus hinzugefuegt (via `GET /api/obsidian/theme`).
- Theme gilt jetzt fuer `home.html` und `settings.html`.
- First-paint Theme-Bootstrap via `localStorage` hinzugefuegt (`homepage-theme-bootstrap-v1`) zur Vermeidung von Theme-Flash.
- Header angepasst: kein Untertitel mehr, Titelgroesse konfigurierbar (`ui.titleSize`), neue Such-Icon-Aktion fuer Omnisearch.
- Neues `beantime`-Modul (Beancount) eingefuehrt, mit Start/Stop-State-Datei und Beancount-Append beim Stop.
- Beantime ergaenzt um `Show`-Button: startet/oeffnet Fava im Obsidian-Webviewer auf Port `3464` in einem neuen Tab.
- Settings-UI kann jetzt innerhalb der Homepage als Modul-Tab verwendet werden (kein Seitenwechsel erforderlich).
- Header-Gear rechts neben der Suche aktiviert die eingebettete Settings-Ansicht.
- Settings-Panels starten standardmaessig eingeklappt.
- Beantime-Running-Panel wird bei gestopptem Timer hart ausgeblendet (`display: none` + `hidden`), um Webviewer-Inkonsistenzen zu vermeiden.

## Neue Module ergaenzen

1. Neue Moduldatei in `Tools/modules/` anlegen und `render...Module` exportieren.
2. In `Tools/app/homepage.js` neues Modul in `moduleRegistry` registrieren.
3. In `Tools/config/settings.default.json` Modul-Konfiguration aufnehmen.
4. Optional in `Tools/settings.html` UI-Toggles/Felder ergaenzen.
5. Falls Backend noetig: Endpoint in `Tools/serve.mjs` ergaenzen.
