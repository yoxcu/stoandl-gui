# stoandl-gui

Kirigami (Qt6/QML) front-end for the stoandl Pebble daemon. Convergent: Plasma Mobile + desktop.
The app lives in `kirigami/` (paths below are under it); app id `de.yoxcu.stoandl.gui`, binary
`stoandl-gui`. Around it: `data/` (`.desktop`/metainfo/flatpak manifest + the hicolor icon tree),
`packaging/kirigami/APKBUILD`, `tools/mock_stoandl.py` and the `.github/` release CI. (A GTK4/libadwaita
front-end used to ship alongside; it was retired on 2026-10-15.)

## Architecture
- QML UI (Kirigami + KirigamiAddons FormCard) + one C++ shim `StoandlClient` (raw `QDBusConnection`).
- Talks to `de.yoxcu.stoandl.Control`, session bus, path `/de/yoxcu/stoandl`. Full contract: the
  daemon repo's `docs/dbus-interface.md` (the one copy; `docs/dbus-interface.md` here links to it). No
  code shared with the daemon — we are just another client.
- Builds musl-native (Alpine/postmarketOS) and glibc (desktop). No JVM.
- **One instance per session** (`src/SingleInstance.*`, plain QtDBus, no KF6 DBusAddons): the first
  process owns the bus name `de.yoxcu.stoandl.gui` (the app id, which a Flatpak may own by default) and
  exports `de.yoxcu.stoandl.Gui.Activate(s token)` at `/de/yoxcu/stoandl/gui`; a later launch calls it
  with its `XDG_ACTIVATION_TOKEN` and exits 0, and the owner raises + `requestActivate()`s its window
  (Qt's Wayland plugin reads that variable there).
- **Window before data.** `WatchPage` (the launch page) starts its loads on the window's first
  `frameSwapped` (a 500 ms timer as the fallback) and builds its three dialogs on first use (a
  `Loader` each, reached through `detailsDialogItem()`/`pairDialogItem()`/`forgetDialogItem()`).
  **`CheckFirmware` is asynchronous** and owned by `StoandlClient`, never called from QML directly:
  `applyWatches` passes the watches' name:state key to `requestFirmwareCheck(key)` (an unchanged key
  reuses the cached answer or joins the call in flight, so the Watch tab coming back doesn't
  re-ask; an `error:` answer or a timeout only for a minute, like the daemon's failed lookups), the
  answer lands in the `firmwareInfo`/`firmwareChecking` properties the banner and
  `WatchDetailsDialog` bind to, and Sync now / Check for updates call `forceFirmwareCheck()`
  (`CheckFirmwareForce`, falling back to `CheckFirmware` on `UnknownMethod`). With `firmware.github`
  on and the release list uncached, the daemon takes ~8 s on a phone: a blocking call there froze the
  first frame past Plasma Mobile’s 8 s launch splash, which then looked like a crash.
- **Tab pages are kept.** `Main.qml` builds each tab's root page on its first visit and then reuses it
  (`tabPages`; WatchPage is declared in the hidden `tabPark` item and is the `initialPage`). Kirigami's
  `PageRow.replace()` puts an item it didn't create back under its original parent instead of
  destroying it, so a hidden tab page waits, invisible, in `tabPark`. A page that comes back gets its
  optional `refreshOnShow()` after the frame that shows it (500 ms timer fallback); handlers that only
  matter while a tab shows (`onDaemonUpChanged` reloads, WatchPage's `onWatchesChanged`) are
  `enabled: page.visible`. `visible` stays true while a sub-page is pushed over the tab, so the
  WatchPage's 20 s poll stops when its tab goes and restarts in `refreshOnShow()`. Pushed sub-pages are
  still created from Components and destroyed when popped. A kept page no longer starts from a fresh
  read, so a control whose bound value its own clicks overwrite (a `FormSwitchDelegate`'s `checked`, see
  below) is set again in the reload callback (the Alerts page's Forward switch).
- **Page loads don't block.** `StoandlClient.fetch(owner, reads, callback)` runs typed reads over
  `QDBusPendingCallWatcher`: one read (`["healthSummary", "day", 0]`) or several in parallel
  (`[["configSchema"], ["getConfig"]]`, callback gets the values in order), named like their
  synchronous `Q_INVOKABLE`. Each read is described once in `readSpec()` (the D-Bus method, a leading
  argument such as GetHealthSeries' metric, the argument types, the parser); the synchronous wrapper
  runs the same entry through `read()`, so a read is fetchable once it has a row there. Latest wins per
  owner, and nothing is delivered after the owner died. Health, Battery (from the rows the Watch page
  passes, then `watchesChanged`), Alerts, Watch settings and Daemon configuration load this way, and
  `refreshApps/Extensions/Plugins()` are asynchronous too (their signals arrive later). A settings
  edit still re-reads synchronously, so its handler can put the control back at once. Per-refresh
  `NameHasOwner` is gone: `NameOwnerChanged` tracks the daemon after the start-up probe.
- **App icons** are cached in `StoandlClient` (uuid → URL, `""` for none) until `LockerChanged`; a
  miss returns `""`, asks `GetAppIcon` asynchronously and announces it with `appIconChanged(uuid,url)`
  (a `none` is re-asked after a minute: the daemon can fetch a `.pbw` after the LockerChanged that
  listed it). The Apps page builds rows only for the segment shown and keeps them when `appsChanged`
  carries an unchanged list.

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
`stoandl.conf` keys — schema-driven like WatchSettingsPage: the daemon's `GetConfigSchema` declares
`key type label options desc group apply min max unit placeholder`, so a new daemon key appears here with
the right widget and no QML change. Five kinds: `toggle`→FormSwitchDelegate, `combo`→FormComboBoxDelegate,
`int`/`text`/`list`→hand-built `AbstractFormDelegate` rows, because FormSpinBoxDelegate and
FormTextFieldDelegate have no `description` property — and FormTextFieldDelegate additionally calls
`i18ndc()`, which throws here for the same reason FormColorDelegate is avoided. Rows are grouped into one
FormHeader+FormCard per `group`, and a row whose `apply` is `restart` says so in its description. Columns
6–11 were **appended** to the original 5-column contract, so parse them with a per-column fallback —
never a hard read), **`BackupSettingsPage`** (backup/restore/support CLI), and
**`DebugSettingsPage`** (the low-level tools, grouped Diagnostics / Recovery / Testing + a danger-zone
factory reset — core dump, watch logs, reboot-to-recovery, flash a local `.pbz`, write a test
notification; they moved here out of the watch-details dialog, and since they all act on *the connected
watch* — the daemon methods take no watch argument — those rows disable with an inline explanation when
none is connected. A watch in its recovery firmware lists as `recovery` in `ListWatches` (the `recovery`
row flag; "In recovery" on the Watch tab): core dump, watch logs and the `.pbz` flash stay enabled for
it — flashing is how it gets back — and the rest disable with a recovery note. Its Diagnostics group also pushes **`HeartbeatPage`**:
the watch's hourly analytics record via `HeartbeatInfo`/`HeartbeatMetrics`, header facts + every metric
grouped by name prefix; when the daemon reports `known=0` it shows *why* nothing is decoded instead of
guessed values. It reads the daemon's stored record, but the daemon resolves the watch argument among
*connected* watches only — with none connected it answers `unknown:` — so the row is gated like the
other Debug tools and the page tells "no watch connected" apart from "nothing captured"). `Main.qml`'s
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
color, schedule}` and the `allowed` field is **pipe-(`|`)-separated** for the option types (NOT comma — the daemon's
`WatchPrefsControl.allowed()`). `StoandlClient::listWatchPrefs()` splits on `|`, pre-derives number
`min/max/unit` (a `"3000 ms"` current is not a plain int — use the leading digits), and a `debug` flag.
Per type: bool→`FormSwitchDelegate`, enum→`FormComboBoxDelegate` (options = `allowed`, **display names**,
not Kotlin constant names — fixed daemon-side), quicklaunch→`FormComboBoxDelegate` of "Off" + the
firmware system actions (Quiet Time, Backlight, …, read from `allowed` between `off` and the
`<app name or uuid>` placeholder) + **app names** (from `ListApps`) (NEVER a slider/uuid), number→`FormSpinBoxDelegate` (unit via `textFromValue`,
**debounce the write** — `onValueChanged` fires every step and `applyPref` rebuilds the list), color→a
swatch + preset combo (the daemon takes a preset *name* back; `FormColorDelegate` is **avoided** — it
calls `i18ndc()` and we deliberately link no KF6 C++ / `KLocalizedContext`), schedule (the Quiet Time
weekday/weekend hours, a 24 h `HH:MM-HH:MM` window; an end before the start runs overnight)→`FormTextRow`
checked as typed by `StoandlClient.normalizeSchedule()` (libpebble3's parse rules, so a bad value is
flagged before the daemon refuses it) and sent zero-padded on Enter/focus-out only. The hours do nothing
until the matching `<id>Enabled` bool is on, and the daemon lists schedules last, so each schedule row is
moved under its switch and names it. Removed/renamed ids stay out of the section rules (`langEnglish` is
now the `language` enum; `dynBacklightMinThreshold`/`lightDynamicIntensity` are gone).

**QML scope gotcha:** a property *binding* inside a nested inline `Component` (a Loader delegate) can't
call a page method (it resolves to a `QQmlComponent`); **handlers can**. So precompute per-row display
data (quick-launch options, color presets) in a page-scope getter and have the delegates read only
`modelData.*`.

## Headless smoke harness

`STOANDL_SMOKE_MS=<ms>` makes the app step through every tab one per tick, call `smokeExercise()` on any
page that defines one, and quit — so `QT_QPA_PLATFORM=offscreen tools/run-with-mock.sh` proves
QML → `StoandlClient` → D-Bus → mock → render end-to-end and self-terminates. The env var is read via `StoandlClient.smokeMs`.
Exercises and the quit go through `Main.smokeWhenIdle(fn)`: queued in order and run once
`StoandlClient.callsInFlight` and `incubatingObjects()` are both 0, so a hook sees the data its page's
asynchronous loads fetched and the rows built from it. A hook that pushes a page and then reads it
(SettingsPage's sub-pages, the WatchPage's BatteryPage) goes through it as well.

**Add a `smokeExercise()` to any page whose interesting state is only reachable by navigation or by a
button press** — otherwise it is not covered. `SettingsPage` pushes all seven sub-pages and runs their
own `smokeExercise()` (`WatchSettingsPage` logs `qlBack`'s quick-launch options and round-trips a Quiet Time window, `DebugSettingsPage` pushes
`HeartbeatPage`, which filters, `GeneralSettingsPage` runs a read-only city search and logs
`stoandl-smoke: weather search <kind>, N places` — `disabled` until `weather.place_search` is on); `NotificationsPage` fires the send-test, steps the Alerts page's
watch-card preview through each `notification.app_name` placement and writes the stored value back
unchanged, then opens the per-app dialog, writes its app-name placement back unchanged and logs its
preview for that override and for Default (each preview as `stoandl-smoke: preview <placement>:
title=… | small=… | …`); `AppsPage` logs the permission request banners (`stoandl-smoke: perm banners …`)
and one app's permission dialog rows (`stoandl-smoke: perms key=status, …`), read-only; `WatchPage` logs the firmware answer (`stoandl-smoke: firmware
checking=… kind=… update=…`), opens the details dialog and logs its firmware state, forces a re-check
(both only with a watch connected), hands the pairing dialog the
daemon's search states (the bare `pending:` and a pause note) and pushes `BatteryPage` even with no
watch connected; with the daemon down the tick presses "Start daemon". The Quiet Time round trip
writes the watch's own window back afterwards (the hook also runs against a real daemon). With
`STOANDL_SMOKE_FLASH=1` the `WatchPage` hook also flashes a `.pbz` that doesn't exist, as Settings → Debug
does (the mock walks any path, a real daemon refuses a missing file), and the app prints every
normalised `firmwareStatus → <kind>` line — how the `prf` handling is checked end to end (run with a
`STOANDL_SMOKE_MS` of ~2400 so the ~11 s walk ends before the quit, ~1900 to reach Settings → Debug while
the watch is in recovery). This harness is how the
delegate-binding scope trap below was caught, so it is worth keeping honest. The mock's
`GetConfigSchema` is the daemon's `GUI_CONFIG_FIELDS` row for row, so the `general loaded N keys in G
groups` line counts the real schema. Mock switches for the states a healthy
mock never reaches: `MOCK_NO_WATCH=1` (paired, nothing connected — also the only way to walk "Pair new
watch", since the daemon opens no window while a watch is connected), `MOCK_PAIR_PAUSE=bt|busy|slept`
(each pairing window starts with that "can't discover" note), `MOCK_HB_UNKNOWN=1` (unverified heartbeat
layout), `MOCK_FW_DOWNGRADE=1` (every sideload is a downgrade through recovery; the watch lists as
`recovery` while it is flashed there, like on the daemon), `MOCK_FW_DOWNGRADE=drop` (the same, but the watch
comes back on its normal firmware and the daemon reports the dropped downgrade as `failed:`),
`MOCK_FW_AUTOSTART=<s>` (a flash the GUI didn't start, seen only through `FirmwareProgress`) and
`MOCK_LINK_PAUSE=manual|quiet_time` (the Watch page starts with that link-paused banner; the smoke walks
Disconnect → Connect either way) and `MOCK_FW_CHECK_MS=<ms>` (`CheckFirmware`/`CheckFirmwareForce` answer
that late without blocking the mock's other calls, like the daemon fetching an uncached GitHub release
list; the mock prints each check as `mock: CheckFirmware #n`, so a smoke log shows how often the GUI asked).

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
  not a guarantee — the re-fetch is authoritative. (Exception: removing an app and launching a face
  rely on `LockerChanged` alone; the daemon pokes it for every locker uuid or active-face change.)
- Returns are either `kind:message` (split on first `:`) or tab-separated `as` records. Parse in
  `StoandlClient`, never in QML. Handle `notready` as the "no watch / not ready" empty state.
- The daemon is NOT D-Bus-activated. If the bus name is unowned → show "daemon not running", offer
  "Start daemon": `systemctl --user reset-failed stoandl`, then `systemctl --user start stoandl` (the
  unit's `StartLimitBurst` refuses a plain start once tripped, silently from a button), and toast a
  failed start with systemctl's own first stderr line (`daemonStartFailed`). Never assume it's up.
- Paths passed to SideloadApp/SideloadFirmware/etc. are **absolute, daemon-side**.
- **Actions stay on the page `actions` (Kirigami renders them: header on desktop, footer toolbar on
  mobile); never hand-place them, NO round floating FAB.** Pages keep their `title`. A page's
  **segment/period switcher** (Health's Daily/Weekly/Monthly + navigator; Apps's Faces/Apps/Extensions)
  is **pinned in the page `header`** (a `QQC2.ToolBar`, `height: visible ? implicitHeight : 0`) so it
  stays put while the content scrolls — NOT inside the scrolling `ColumnLayout`. (History: page titles
  were briefly blanked to save space, then restored — the toolbar row is there for the actions anyway,
  so the title may as well use it.)
- **Never hardcode colors or fonts.** Use `Kirigami.Theme` roles + `Kirigami.Units` spacing. The
  prototype's dark hexes are a density spec, not a color spec. The one exception is
  `WatchCardPreview` (the Alerts page and the per-app dialog): it depicts the watch's own notification
  card — white, black text, a banner in the app's colour — so it looks the same in either theme. Its
  `lines` is the GUI's only copy of the daemon's app-name rule (`watchFields()`).
- Row actions are **inline** (trailing buttons in the delegate), **not kebabs**.

## Status kinds
ok · error · notready · notfound · ambiguous · pending · timeout · inprogress · reboot · failed ·
done · uptodate · disabled · busy · idle · none · confirm (PairStatus `confirm:<code>` — numeric
comparison awaiting ConfirmPairing(bool)) · prf (FirmwareStatus `prf:<version>` — a downgrade on a
dual-slot watch rebooting into recovery with nothing flashed yet; the daemon flashes the same `.pbz`
once the watch reconnects there. The disconnect that follows is NOT success: `StoandlClient` restarts
the activity tracking and timeout at the first `prf`, holds the phase across `notready`/`idle`, and only
the flash from recovery ends the op — like the CLI's `pollFirmwareStatus`)

## Daemon hooks (added this milestone)
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
regex filters; the per-app app-name placement (`NotifSetAppName` + `NotifList`'s 7th column, the
override of `notification.app_name`; empty = follows it); a changelog URL on `CheckFirmware`. All are
implemented in the mock (`tools/mock_stoandl.py`) and must be grown in the real Kotlin daemon to match.
(Notification quiet-hours hooks were dropped — superseded by the daemon's `dnd.sync`.)

## Not on D-Bus (shell out to the `stoandl` CLI, co-located): backup, restore, support bundle.

## Design reference
Target look/layout/states = the "KDE Kirigami by-the-book" prototype (`docs/stoandl KDE by-the-book.html`
→ `docs/kde-hig.jsx`). Match its FormCard grouping, page-action placement (header/footer toolbar, NOT a
FAB), passive-notification toasts, and danger-zone styling — in structure and density, taking colors
from the system theme.
