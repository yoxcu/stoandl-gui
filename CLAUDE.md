# stoandl-gui

Kirigami (Qt6/QML) front-end for the stoandl Pebble daemon. Convergent: Plasma Mobile + desktop.

## Architecture
- QML UI (Kirigami + KirigamiAddons FormCard) + one C++ shim `StoandlClient` (raw `QDBusConnection`).
- Talks to `de.yoxcu.stoandl.Control`, session bus, path `/de/yoxcu/stoandl`. Full contract:
  `docs/handoff/dbus-interface.md`. No code shared with the daemon — we are just another client.
- Builds musl-native (Alpine/postmarketOS) and glibc (desktop). No JVM.

## Navigation — 5 tabs (current)
**Watch · Health · Apps · Notifications · Settings** in `Kirigami.NavigationTabBar` (KDE HIG: ≤5
destinations → tab bar, not a drawer). **Watch is tab 0** (the launch view). Responsive: the tab bar is
in the window *footer*, so it sits BELOW content on mobile and relocates ABOVE on desktop. Extensions
are the 3rd segment of **Apps** (Faces / Apps / Extensions). Sync services live in **Settings**. The nav
is hidden when the daemon is down (nothing works without it).

**Settings is a category landing, not one page.** `SettingsPage.qml` is a short list of
`FormButtonDelegate` rows that `pageStack.push()` focused sub-pages (KDE HIG for a large settings
surface): **`SyncSettingsPage`** (service master toggles + force-sync), **`CalendarsSettingsPage`**
(calendar *sources* — CalDAV accounts / iCal feeds / .ics — each account's discovered calendars nested
under it with per-calendar enable toggles, plus an add/edit/delete dialog; the CalDAV **password field
is write-only**, blank on edit = keep), **`WatchSettingsPage`** (the ~46 WatchPrefs, grouped into
FormHeader sections and rendered one delegate *per type* — see below), **`GeneralSettingsPage`** (the
curated `stoandl.conf` keys), **`BackupSettingsPage`** (backup/restore/support CLI). `Main.qml`'s
`showTab()` pops pushed sub-pages on tab-switch and on re-tapping the active tab. (Calendars used to be
a flat list nested in SyncSettingsPage; they moved to their own page when account grouping + CRUD landed.)

**Health is period-based** (mirrors the official Pebble app's `HealthTimeRange`). One selector
(Daily/Weekly/Monthly) + one navigator (`periodType`/`periodOffset`) drive all three sections.
`day` = rich per-day cards (hourly step bars, sleep timeline, minute-level HR line); `week`/`month` =
per-day bar charts (reusable `MetricBars`: faded bar + solid stacked `deep` + a `refLine` typical +
`floorAtMin` for HR + sparse labels). Daemon: `GetHealthSummary(periodType,offset)` (20 fields) +
`GetHealthSeries(metric,periodType,offset)`; C++ `healthSummary/stepsBars/sleepTimeline/sleepBars/
heartSamples/heartBars(pt,off)`. **No step goal** (dropped); "typical" comes from `getTypicalSteps().sum()`.
`hrAvailable` only means "watch has an HRM" — gate the HR average/bars on `hrAvg > 0` and show an empty
state otherwise (a real past month can be HRM-capable but have no readings).

**WatchPrefs widgets (the gotchas).** `ListWatchPrefs` types are `{bool, number, enum, quicklaunch,
color}` and the `allowed` field is **pipe-(`|`)-separated** for the option types (NOT comma — the daemon's
`WatchPrefsControl.allowed()`). `StoandlClient::listWatchPrefs()` splits on `|`, pre-derives number
`min/max/unit` (a `"3000 ms"` current is not a plain int — use the leading digits), and a `debug` flag.
Per type: bool→`FormSwitchDelegate`, enum→`FormComboBoxDelegate` (options = `allowed`, **display names**,
not Kotlin constant names — fixed daemon-side), quicklaunch→`FormComboBoxDelegate` of **app names**
(from `ListApps`) + "Off" (NEVER a slider/uuid), number→`FormSpinBoxDelegate` (unit via `textFromValue`,
**debounce the write** — `onValueChanged` fires every step and `applyPref` rebuilds the list), color→a
swatch + preset combo (the daemon takes a preset *name* back; `FormColorDelegate` is **avoided** — it
calls `i18ndc()` and we deliberately link no KF6 C++ / `KLocalizedContext`).

**QML scope gotcha:** a property *binding* inside a nested inline `Component` (a Loader delegate) can't
call a page method (it resolves to a `QQmlComponent`); **handlers can**. So precompute per-row display
data (quick-launch options, color presets) in a page-scope getter and have the delegates read only
`modelData.*`.

## Hard rules
- **The interface has SEVEN signals (`WatchesChanged`/`FirmwareProgress`/`LockerChanged`/
  `LanguageProgress`/`ExtensionsChanged`/`ExtensionStateChanged`/`CalendarsChanged`) that augment
  polling — polling stays as the fallback.** (`CalendarsChanged` → `refreshCalendars()`: the daemon
  pokes it when an async sync adds/drops calendars after a source CRUD, so the Calendars page updates
  when the data's ready; the page also keeps a short post-mutation settle-timer as the fallback.)
  The daemon is NOT D-Bus-activated, so a late or reconnecting client can miss a signal; therefore
  the GUI keeps a slow safety-net poll **and** re-syncs on `daemonUpChanged`. All of this lives in
  `StoandlClient`: the signals re-use the existing `refreshWatches()`/`refreshApps()`/
  `refreshExtensions()`/`firmwareStatus(...)`/`languageStatus(...)` paths (QML unchanged); a 20s
  watch poll carries `BluetoothStatus` + is the missed-`WatchesChanged` net; op pollers for
  Pair/Firmware/Language stay (the firmware/language op-poll is the reboot/disconnect watchdog —
  the `FirmwareProgress`/`LanguageProgress` signal just smooths its % between ticks, so the
  language op-poll is relaxed to a 3s watchdog cadence). `ExtensionStateChanged(s name, s state)`
  is the finer companion to the `ExtensionsChanged` poke: it carries an unsolicited per-extension
  run-state transition (`ready`/`exited`/`quarantined`) the list-level poke can't — `StoandlClient`
  records it in a name→state map and merges it into the `ExtList` rows (so a quarantined/exited ext
  isn't shown as a stale "running"). UI never polls directly.
- **After any mutating call, still re-fetch that screen's list.** The signal is a best-effort poke,
  not a guarantee — the re-fetch is authoritative.
- Returns are either `kind:message` (split on first `:`) or tab-separated `as` records. Parse in
  `StoandlClient`, never in QML. Handle `notready` as the "no watch / not ready" empty state.
- The daemon is NOT D-Bus-activated. If the bus name is unowned → show "daemon not running", offer
  `systemctl --user start stoandl`. Never assume it's up.
- Paths passed to SideloadApp/SideloadFirmware/etc. are **absolute, daemon-side**.
- **Actions stay on the page `actions` (Kirigami renders them: header on desktop, footer toolbar on
  mobile); never hand-place them, NO round floating FAB.** Pages keep their `title`. A page's
  **segment/period switcher** (Health's Daily/Weekly/Monthly + navigator; Apps's Faces/Apps/Extensions)
  is **pinned in the page `header`** (a `QQC2.ToolBar`, `height: visible ? implicitHeight : 0`) so it
  stays put while the content scrolls — NOT inside the scrolling `ColumnLayout`. (History: page titles
  were briefly blanked to save space, then restored — the toolbar row is there for the actions anyway,
  so the title may as well use it.)
- **Never hardcode colors or fonts.** Use `Kirigami.Theme` roles + `Kirigami.Units` spacing. The
  prototype's dark hexes are a density spec, not a color spec.
- Row actions are **inline** (trailing buttons in the delegate), **not kebabs**.

## Status kinds
ok · error · notready · notfound · ambiguous · pending · timeout · inprogress · reboot · failed ·
done · uptodate · disabled · busy · idle · none · confirm (PairStatus `confirm:<code>` — numeric
comparison awaiting ConfirmPairing(bool))

## Daemon hooks (added this milestone — see the drift report `docs/handoff/drift-report.md`)
Seven reactive **signals** — `WatchesChanged()` (re-call ListWatches), `FirmwareProgress(s phase,
i percent, s detail)` (push flash progress, same phase vocabulary as `FirmwareStatus`),
`LockerChanged()` (re-call ListApps), `LanguageProgress(s phase, i percent, s detail)` (push
language-install progress, same phase vocabulary as `LanguageStatus`), `ExtensionsChanged()`
(re-call ExtList), `ExtensionStateChanged(s name, s state)` (the finer companion to
`ExtensionsChanged`: an unsolicited per-extension run-state transition — `state` ∈
`ready`/`exited`/`quarantined` — that the list-level poke can't catch, so a crashed/quarantined
extension shows live instead of a stale "running"), and `CalendarsChanged()` (re-call ListCalendars —
the daemon pokes it when an async sync adds/drops calendars after a source CRUD) — consumed on top of
polling (see Hard rules).
The GUI also consumes daemon-side hooks beyond the original 51 methods: `transport` on ListWatches +
`synced` on ListApps (#4); `GetSyncStatus`/`SetSyncEnabled` (#5); `ExtList.config` + `ExtOpenConfig` +
`ExtConfigSchema`/`ExtGetConfig`/`ExtSetConfig` (#7); `GetHealthSummary`/`GetHealthSeries` (#8);
`SetWatchNickname` (#9); `GetConfigSchema`/`GetConfig`/`SetConfig` (#10); `WatchDetails`; notification
regex filters; a changelog URL on `CheckFirmware`. All are implemented in the mock
(`tools/mock_stoandl.py`) and must be grown in the real Kotlin daemon to match. (Notification
quiet-hours hooks were dropped — superseded by the daemon's `dnd.sync`.)

## Not on D-Bus (shell out to the `stoandl` CLI, co-located): backup, restore, support bundle.

## Design reference
Target look/layout/states = the "KDE Kirigami by-the-book" prototype (`docs/stoandl KDE by-the-book.html`
→ `docs/kde-hig.jsx`). Match its FormCard grouping, page-action placement (header/footer toolbar, NOT a
FAB), passive-notification toasts, and danger-zone styling — in structure and density, taking colors
from the system theme.
