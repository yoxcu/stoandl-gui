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
  `WatchDetailsDialog` bind to, and Check for updates calls `forceFirmwareCheck()`
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
  below) follows its value from a handler, not a binding (the settings rows' `Connections`).
- **Page loads don't block.** `StoandlClient.fetch(owner, reads, callback)` runs typed reads over
  `QDBusPendingCallWatcher`: one read (`["healthSummary", "day", 0]`) or several in parallel
  (`[["configSchema"], ["getConfig"]]`, callback gets the values in order), named like their
  synchronous `Q_INVOKABLE`. Each read is described once in `readSpec()` (the D-Bus method, a leading
  argument such as GetHealthSeries' metric, the argument types, the parser); the synchronous wrapper
  runs the same entry through `read()`, so a read is fetchable once it has a row there. Latest wins per
  owner, and nothing is delivered after the owner died. Every page load goes this way (Diagnostics, the
  heartbeat, the health profile, the watch details, the calendar accounts, the voice cards' download
  poll too), and `refreshWatches/Apps/Extensions/Plugins/Calendars()` are asynchronous as well (their
  signals arrive later; `refreshWatches()` runs ListWatches, BluetoothStatus and LinkPause in parallel).
  A settings edit still re-reads synchronously, so its handler can put the control back at once.
  Per-refresh `NameHasOwner` is gone: `NameOwnerChanged` tracks the daemon after the start-up probe.
- **Slow actions run, not block.** `StoandlClient.run(owner, ["name", args…], callback)` runs one
  `readSpec()` row without blocking, like a one-read `fetch()` but never dropped for a newer call: the
  syncs, the city search, `LaunchApp`, `UpdateFirmware`, `Ping` and `Transcribe` (their rows carry the
  CLI's 120 s timeout; `afterRead()` starts the flash poll for UpdateFirmware). The syncs, the search,
  LaunchApp and UpdateFirmware have no blocking `Q_INVOKABLE` at all, so nothing can freeze the UI on them.
  `callsInFlight` counts every asynchronous call; its `userCallsInFlight` part (fetch and run, what
  someone waits for) drives Main.qml's one thin indeterminate bar along the top (after 300 ms).
- **Watch tasks.** Sideload, screenshot, watch logs and core dump only start on the daemon
  (`ok:started`, with an empty path the daemon picks the file under Pictures/Screenshots or
  Documents/stoandl). `StoandlClient` follows the ones it started through `TaskChanged` (a 2 s
  `TaskStatus` poll is the fallback, ten minutes the ceiling; a poll still out from an earlier task of the
  kind is dropped by a per-kind generation), lists them in `tasks` and ends each with
  `taskFinished(kind, result)`; Main.qml reports every result, whichever page started it: a screenshot
  opens `ScreenshotDialog` (Open / Open folder / Take another), logs and dumps toast with Open folder.
  The Flatpak manifest shares both folders (`create`) so the sandboxed GUI can show and open the files;
  where it still can't, the preview and `openSaved()` say so.
- **D-Bus failures are worded once**, in `StoandlClient`'s `errorText()`: no reply → "stoandl didn't
  answer in time (it may still be working)", unknown method → "Your stoandl daemon is older than this
  app", an unowned name → "stoandl isn't running" or, while the daemon holds its private
  `de.yoxcu.stoandl.Instance` name but not yet the public one (it takes that last), "still starting".
  The raw error is logged. A status call carries it as `{kind: error, tail}`; a list read that failed
  is named in `readErrors` (read name → why), which `ReadErrorMessage` shows so a page doesn't pass it
  off as an empty list. `daemonState` (up / starting / flatpak / nosystemd / notinstalled / startlimit /
  failed / stopped, the last four from `systemctl --user show stoandl`, asked again 1.5 s after a name
  goes and every 10 s while the daemon stays down) words `DaemonPlaceholder`. The Flatpak manifest
  grants `--talk-name` for both the public and the `.Instance` name (each is exact).
- **Cached reads.** A `readSpec()` row marked `cached` is answered from `StoandlClient` for the daemon
  running now (through `read()` and `fetch()` alike): the config schema and `NotifStyleChoices`. All are
  dropped when the daemon goes or comes; the schema also on every `ConfigChanged` and when a
  `voiceModels` read sees the installed set change (the model and voice dropdowns list them), and both
  when `notifSetVibePattern()` changes a custom vibration. A page open costs a GetConfig (and
  GetSyncStatus), not the schema. `StoandlClient.forwarding` (notification.forward, read on daemonUp and
  its ConfigChanged) and `mutedUntil` (the mute-all's end, `NotifMuteAllStatus`, read on daemonUp, after
  `notifSetMuteAll()`, with every `refreshWatches()` and when the app comes to the front; its end is
  checked against the wall clock each minute, since a timer's clock stops in suspend) drive the Alerts banner and the
  Watch tab's chips; `restartPending` lists the keys `setConfig()` was told apply after a restart
  (cleared when the daemon goes or comes), and `busyOp` (pairing / firmware / language) the op poll that
  keeps "Restart now" waiting.
- **Main.qml holds the window-wide pieces:** `confirm(heading, text, actionText, icon, onConfirm)` (one
  `ConfirmDialog` for what can't be put back; what can be acts at once with Undo on its toast),
  `dialogWidth(units)` (every dialog's width, never wider than the window), `turnOnForwarding()`,
  `resumeNotifications()` and `formatUntil(epoch)`. `ConfigKey { key }` is how an empty state offers the
  one switch that fills it, with the schema's label and egress ("Contacts …").
- **Sub-pages are pushed with `Main.pushPage(component, props)`**, never `pageStack.push(Component)`:
  Kirigami creates a pushed Component with a QtObject parent, which makes Qt warn "Created graphical
  object was not placed in the graphics scene" for every page. `pushPage` creates it without a parent
  and destroys it a `humanMoment` after PageRow removes it (destroyed at once, the form rows of the page
  sliding out loop on their background colour).
- **App icons** are cached in `StoandlClient` (uuid → URL, `""` for none) until `LockerChanged`; a
  miss returns `""`, asks `GetAppIcon` asynchronously and announces it with `appIconChanged(uuid,url)`
  (a `none` is re-asked after a minute: the daemon can fetch a `.pbw` after the LockerChanged that
  listed it). The Apps page builds rows only for the segment shown and keeps them when `appsChanged`
  carries an unchanged list.

## Navigation — 5 tabs (current)
**Watch · Health · Apps · Notifications · Settings** in `Kirigami.NavigationTabBar` (KDE HIG: ≤5
destinations → tab bar, not a drawer). **Watch is tab 0** (the launch view). Responsive: the tab bar is
in the window *footer*, so it sits BELOW content on mobile and relocates ABOVE on desktop. Extensions
are the 3rd segment of **Apps** (Faces / Apps / Extensions). Sync services are their master keys' rows in
**Settings** (one control per key: there is no Sync page). The nav
is hidden when the daemon is down (nothing works without it).

**Settings is a category landing, not one page.** `SettingsPage.qml` lists, in a static order that
holds only icons: **Watch preferences** (`WatchSettingsPage`), one entry per **schema page**
(Notifications, Weather, Calendar, Music, Voice, Health & battery, Apps & plugins, Connection & power,
Firmware & language — `SchemaSettingsPage { pageName }`), **Backup & restore**, **Diagnostics &
developer** (`DebugSettingsPage`, with the schema page "Developer" on top) and **About** (GUI and daemon
versions, licence, a copyable support line; the GUI version is CMake's `STOANDL_GUI_VERSION`, which the
APKBUILD sets to its pkgver and the release CI to the tag in the Flatpak manifest, else `git describe` of
the gui checkout itself, else `project()`'s VERSION — keep that in step with the tags). A schema page's description is its section titles (Advanced
ones left out) joined by " · "; a schema page the list doesn't name shows up under **More**, so a page
the daemon adds is never dropped. A `Kirigami.SearchField` on top (200 ms debounce) matches every word
in a key's label, description, help or key, and — read on the field's focus, since it can block 5 s
daemon-side, and asked again on the next focus or watch-list change while the answer is empty (no watch
yet) — a watch pref's name, description, help or id; a hit ("Label — Page › Section") pushes
its page with `focusKey`/`focusId`, which builds that page's rows and cards at once, scrolls to the row and
flashes it (`FocusFlash`, which scrolls back to the row while it flashes if the page's height changes). `Main.qml`'s `showTab()` pops pushed sub-pages on tab-switch and on re-tapping the
active tab.

**Schema pages** (`SchemaSettingsPage` = a ScrollablePage around **`SchemaSections`**, which Debug also
embeds). The daemon's `GetConfigSchema` (16 columns: `key type label options desc group apply min max
unit placeholder page help requires default egress`; appended columns are parsed with a per-column
fallback, never a hard read — a daemon without `page` puts everything on one "Daemon configuration" page)
declares every key, so a new daemon key appears on its page with the right widget and no QML change.
Kinds: `toggle`→`FormSwitchRow`, `combo`→`FormOptionRow`, `int`→`FormSpinRow`, `text`→`FormTextRow`,
`list`→`FormListRow`, `secret`→a password `FormTextRow` + Remove. Rows are grouped by `group` into
FormHeader+FormCard sections; sections titled `Advanced …` (a page's last) sit behind one "Advanced
settings (N)" row, collapsed, and their row Loaders are inactive until it opens. A row whose `requires`
(`key=value|key!=value` alternatives in GetConfig's spelling, parsed in `StoandlClient`) doesn't hold is
**locked, not hidden** (`locked`: the control is off but the row's help still opens — `enabled: false`
would disable the (?) with it), and its subtitle ends "· Used when “Label” is value". A master whose
service has nothing to read yet (GetSyncStatus `no source`) says "No place yet" / "No calendar source
yet", not "Not available here". A service's master row
(GetSyncStatus' `key` column) adds its "Last sync · …" or, for Music, what plays; Weather, Calendar and
Health & battery get a "Sync now" page action. A key that applies after a restart says "(after restart)"
in its subtitle, and setting one shows `RestartMessage` ("Restart stoandl to apply: … [Restart now]" →
`Restart()`, which goes through the daemon's own service manager, so it works from the Flatpak). Cards
and links are anchored to a **key**, not a section title: `VoiceModelsCard { kind: "stt" }` under the
section holding `voice.local_model`, `{ kind: "tts" }` (with Test voice → `Speak`) under
`tts.local_voice`'s, `WeatherSearchCard` under `weather.place_search`'s; inside the section, right after
the key's row, the `WatchCardPreview` after `notification.app_name`, an "Accounts and feeds" link
(`CalendarsSettingsPage`) after `calendar.discover` and a "Health profile" link
(`HealthProfileSettingsPage`) after `health.sync`. Every `ConfigChanged` re-reads the page (200 ms
debounce), so `stoandl daemon set` and other clients show at once.

**Row help** (the KDE HIG pattern: one line inline, the rest behind "?"). Every row component
(`FormSwitchRow`, `FormOptionRow`, `FormTextRow`, `FormSpinRow`, `FormListRow`) takes `help` and builds one
`RowHelp` (Kirigami.ContextualHelpButton: switch → trailing, option row → before the value, the others →
next to the label), hidden while `help` is empty, and `locked` (the control off, the help still on; the
option row emits `activated`, not a bare `clicked`, so a locked one opens no picker — `FormSwitchRow` is
our own row for the same reason: FormSwitchDelegate's inner Switch follows only `enabled`). A long press (on the label for text/spin/list rows,
whose field owns the rest), a right click or F1/Menu open the same tooltip; a long press opens it on
release (a tooltip opened during the press closes on the release) and, with pressAndHold connected,
neither flips a switch nor opens a picker. `Accessible.description` is the description plus the help. A
schema row's help is the daemon's `help` plus a generated line: "Default: … Contacts <egress>. Applies
after restarting stoandl. stoandl.conf key: …". The Health profile rows and the extension settings
form (a manifest field's optional `description`/`help`) use the same rows.

**The other settings pages.** `CalendarsSettingsPage` ("Accounts and feeds": calendar *sources* — CalDAV
accounts / iCal feeds / .ics — each account's discovered calendars nested under it with per-calendar
enable toggles, plus an add/edit/delete dialog; the CalDAV **password field is write-only**, blank on
edit = keep), **`WatchSettingsPage`** (see WatchPrefs below), **`BackupSettingsPage`** (backup/restore
CLI) and **`DebugSettingsPage`** ("Diagnostics & developer": the Developer keys, then the support bundle
(CLI), watch logs, core dump, the heartbeat, recovery, testing and a danger-zone factory reset; since the
watch tools act on *the connected watch* — the daemon methods take no watch argument — those rows disable
with an inline explanation when none is connected. A watch in its recovery firmware lists as `recovery`
in `ListWatches` (the `recovery` row flag; "In recovery" on the Watch tab): core dump, watch logs and the
`.pbz` flash stay enabled for it — flashing is how it gets back — and the rest disable with a recovery
note. Its Diagnostics group also pushes **`HeartbeatPage`**: the watch's hourly analytics record via
`HeartbeatInfo`/`HeartbeatMetrics`, header facts + every metric grouped by name prefix; when the daemon
reports `known=0` it shows *why* nothing is decoded instead of guessed values. It reads the daemon's
stored record, but the daemon resolves the watch argument among *connected* watches only — with none
connected it answers `unknown:` — so the row is gated like the other Debug tools and the page tells "no
watch connected" apart from "nothing captured"; Testing also has Ping the watch). The Alerts tab keeps
the temporary mute of every app ("Muted until 15:00 [Resume now]"), the per-app list (a search field,
Recent / By name; each row says its mute — "Muted until 14:30", "Muted on weekdays" — from `muteKind`,
and its switch toggles only on/off, opening the app's dialog for a schedule or a mute that ends) and
filters (a deleted one has Undo), a "Notification settings" action to Settings → Notifications, and a
`ForwardingBanner` ("Forwarding is off … [Turn on]") while notification.forward is off; the key's one
control is the first row of Settings → Notifications. The per-app dialog has a Mute row (Unmuted /
Muted / Muted on weekdays / Muted at weekends, notification.default_mute's words), 30 min / 1 hr / Today
(a duration to midnight), the vibrations with a custom-vibration editor (NotifSetVibePattern), and icon,
colour and app-name rows on the page's OptionPicker that show the stored values. The Watch tab shows
the same two states as `ActionChip`s ("Forwarding off [Turn on]", "Muted until 15:00 [Resume]"); its
pairing dialog says how to pair (Settings → Bluetooth on the watch), offers "Turn on Bluetooth Classic"
(SetConfig + Restart, then opens again) before it searches while classic.discover is off, and Retry
after a timeout; Re-pair (a disconnected watch's row, the watch details) asks first. Sync now runs the
weather, calendar and health syncs that are on; Check for updates is its own action. Pull to refresh on
Watch, Health, Apps, Alerts and Accounts and feeds re-reads that page and nothing else.

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
`min/max/unit` (a `"3000 ms"` current is not a plain int — use the leading digits), and a `debug` flag;
**`notifWindowTimeout` alone is shown in seconds** (`scale` 1000: the page sends value × scale; the
backlight timeout stays in ms, whose sub-second values whole seconds would lose). The **sections are the
daemon's** (column 8, in the order it lists them; "Advanced" — its diagnostic prefs — collapsed like a
schema page's; an older daemon's prefs all land in "Other"), the (?) holds its `help` (column 9) and the
default, and `requires` (column 10, `id=value` in the `current` spelling) disables a row with "· Used
when …", as on the schema pages. "Reset to defaults" (page action, confirmed) calls `ResetWatchPrefs`.
Per type: bool→`FormSwitchRow`, enum→`FormOptionRow` (options = `allowed`, **display names**,
not Kotlin constant names — fixed daemon-side), quicklaunch→`FormOptionRow` of "Off" + the
firmware system actions (Quiet Time, Backlight, …, read from `allowed` between `off` and the
`<app name or uuid>` placeholder) + **app names** (from `ListApps`) (NEVER a slider/uuid), number→`FormSpinRow` (unit via `textFromValue`,
**debounce the write** — `onValueChanged` fires every step and each commit is a D-Bus write + re-read), color→a
`FormOptionRow` with a swatch and the presets (the daemon takes a preset *name* back; `FormColorDelegate` is **avoided** — it
calls `i18ndc()` and we deliberately link no KF6 C++ / `KLocalizedContext`), schedule (the Quiet Time
weekday/weekend hours, a 24 h `HH:MM-HH:MM` window; an end before the start runs overnight)→`FormTextRow`
checked as typed by `StoandlClient.normalizeSchedule()` (libpebble3's parse rules, so a bad value is
flagged before the daemon refuses it) and sent zero-padded on Enter/focus-out only. The hours do nothing
until the matching `<id>Enabled` bool is on (the daemon's `requires` says so), and the daemon lists
schedules last, so each schedule row is moved under its switch.

**Stable settings rows** (`WatchSettingsPage`, `SchemaSections`). The Repeaters' model is only the
*shape* — sections of `{key|id, type}` — and is reassigned only when it really changes, so opening a page
builds each row once and an edit or re-read builds nothing (it used to rebuild all ~80 rows per edit,
0.4-0.7 s on x86). Everything else lives in two page maps: the schema/pref per key (entries keep their JS
identity while unchanged, `StableRows.reuse()`, so only a row whose data moved re-evaluates) and the
values. After a set, re-read only the values (`GetConfig` / `ListWatchPrefs`) and let the rows patch
themselves; every handler then puts its control back on the re-read value, because a value the daemon
refused leaves the data unchanged and fires no binding. **`FormSwitchDelegate.checked` can't be bound**:
the delegate assigns it from its inner Switch, which drops the binding at creation, so a switch row
follows its value from a `Connections` handler. **One-of-several rows are `FormOptionRow`** (name, stored
value, down arrow — what FormComboBoxDelegate shows in its mobile Dialog mode): FormComboBoxDelegate
builds a hidden QQC2.ComboBox, a delegate per option and an InlineMessage for every row whatever its
display mode, ~10 ms a row on x86 (Watch settings opened in ~3 s on the OnePlus 6). A click opens the
page's ONE `OptionPicker` (a dialog of radio rows, built on first use by `pickOption()`), whose callback
applies the pick; the row shows only the stored value, so a refused pick needs no putting back. The
first section's row Loaders are synchronous (the screen the page opens on is complete in its first
frame), the rest `asynchronous` (holding a placeholder height until ready): a fully synchronous build
blocked ~0.35 s (Watch) / ~0.9 s (the old one-page daemon configuration) on x86, more than the push
animation can hide. The cards are created once at page level (asynchronously, except for a search hit) and moved into the
`cardSlot` of the section holding their anchor key. Destroying a page while its rows are still incubating can leave Qt's
in-progress-creation count behind (the engine then warns "There are still N items in the process of
being created" at exit), so the smoke clears the page stack and quits only once nothing incubates.
An edit bumps the page's `editSeq`; a `reload()` fetch that started before it (its reply lands after
the edit's synchronous re-read) applies its schema but keeps the re-read values.

**QML scope gotcha:** a property *binding* inside a nested inline `Component` (a Loader delegate) can't
call a page method (it resolves to a `QQmlComponent`); **handlers can**. So precompute per-row display
data (quick-launch options, color presets) in page scope and do the per-row lookup on the Loader itself
(`readonly property var pref: page.prefMap[modelData.id]`, where `page` resolves); the inline Components
read only the Loader's properties.

## Headless smoke harness

`STOANDL_SMOKE_MS=<ms>` makes the app step through every tab one per tick, call `smokeExercise()` on any
page that defines one, and quit — so `QT_QPA_PLATFORM=offscreen tools/run-with-mock.sh` proves
QML → `StoandlClient` → D-Bus → mock → render end-to-end and self-terminates. The env var is read via `StoandlClient.smokeMs`.
Exercises and the quit go through `Main.smokeWhenIdle(fn)`: queued and run once
`StoandlClient.callsInFlight`, its `tasks` and `incubatingObjects()` are all empty, so a hook sees the data its page's
asynchronous loads fetched and the rows built from it. One fn runs per 50 ms check, so the D-Bus signals
a fn's calls cause (ConfigChanged …) are dispatched, and their reads started, before the next looks; and
the queue is **depth first**: what a running fn queues runs before the rest, so a page's walk (and what
its hooks queue in turn) ends before the next step pops that page. The next tab, and the quit, wait for
an empty queue, so every exercise runs while its page shows. `STOANDL_SMOKE_SIZE=360x740` (with
`QT_QUICK_CONTROLS_MOBILE=1`) walks at a phone's size and mode. A
hook that pushes a page and then reads it (SettingsPage's sub-pages, the WatchPage's BatteryPage) goes
through it as well; a hook that pushes a page pops it again (one page at a time, as someone would).

**Add a `smokeExercise()` to any page whose interesting state is only reachable by navigation or by a
button press** — otherwise it is not covered. `SettingsPage` logs its entries and their generated
descriptions, searches ("quiet": schema and watch-pref hits, `stoandl-smoke: search …`), opens a hit
(`stoandl-smoke: revealed <key>`), then opens every entry in turn, runs its hook and goes back, and
finally (mock only) writes a restart key back unchanged, logs the restart message, presses Restart now
and waits for the daemon to come back with nothing pending. `WatchSettingsPage` logs the daemon's
sections, a row its `requires` disables, `notifWindowTimeout` in seconds and a help text, resets to
defaults (mock only), presses `qlBack`'s row and picks the stored option in the picker
(`stoandl-smoke: picker …`), and round-trips a Quiet Time window. Each schema page (`SchemaSections`)
logs where its cards and anchors sit and which rows are locked and why, opens a locked row's help
(`stoandl-smoke: locked <key> help enabled=true shown=true`), opens its first row's help as
a long press does (`stoandl-smoke: help <key> shown=true · <text>`), long-presses its first combo row
(help, no picker) and then does the picker round trip on it, runs a read-only city search on Weather,
speaks the test sentence and stops it on Voice (`stoandl-smoke: tts …`), and follows its links
(Accounts and feeds, Health profile, whose hook does a Units picker round trip). `DebugSettingsPage`
runs the Developer keys' hook and pushes `HeartbeatPage`, which filters; `AboutSettingsPage` logs its
support line; it also starts a watch-logs and a core-dump task and pings (each result is logged as
`stoandl-smoke: task <kind> -> …`). `HealthPage` logs its Health data offer and a pull to refresh.
`NotificationsPage` fires the send-test, logs the per-app rows' mutes and a search, turns forwarding off
(mock only) and logs the banner, presses its Turn on, mutes all for 30 minutes and resumes (mock only),
then opens the per-app dialog, logs its rows, writes its app-name placement to Default and back and
logs the preview for each (`stoandl-smoke: preview <placement>: title=… | small=… | …`), and (mock only)
saves and removes a custom vibration; `AppsPage` logs its plugins offer, opens and cancels a confirm, starts
a sideload task (mock only), crashes and restarts an extension (mock only, its last stderr line), opens an extension's settings form and logs its fields
(`[desc]`/`[help]`) and the values Save would send, then opens it again (`reopened same=true`: the rows
are built against the stored values, not the previous open's), the permission request banners (`stoandl-smoke: perm
banners …`) and one app's permission dialog rows (`stoandl-smoke: perms key=status, …`), read-only;
`WatchPage` logs the firmware answer (`stoandl-smoke: firmware checking=… kind=… update=…`), opens the
details dialog and logs its firmware state, forces a re-check, runs Sync now and takes a screenshot
(whose preview Main.qml opens and closes) (all only with a watch connected), hands the pairing dialog the
daemon's search states (the bare `pending:`, a pause note, a timeout's hint and Retry) and (mock only)
opens it with Bluetooth Classic off, pushes `BatteryPage` even with no watch connected, walks
Disconnect → Connect and (mock only) the mute chip's Resume; with the daemon down the tick logs
`daemonState` and presses "Start daemon". The
Quiet Time round trip writes the watch's own window back afterwards (the hook also runs against a real
daemon). With `STOANDL_SMOKE_FLASH=1` the `WatchPage` hook also flashes a `.pbz` that doesn't exist, as
Settings → Diagnostics & developer does (the mock walks any path, a real daemon refuses a missing file),
and the app prints every normalised `firmwareStatus → <kind>` line — how the `prf` handling is checked
end to end (run with a `STOANDL_SMOKE_MS` of ~2400 so the ~11 s walk ends before the quit, ~1900 to reach
Settings → Diagnostics & developer while the watch is in recovery). This harness is how the
delegate-binding scope trap below was caught, so it is worth keeping honest. The mock's
`GetConfigSchema` is the daemon's own (`tools/config-schema.tsv`, written by its ConfigSchemaTest) and its
watch-pref sections, help and requires are too (`tools/watch-pref-text.tsv`), so the `schema page '<page>'
N keys in S sections` lines count the real schema. A clean walk prints no warning at all. (Kirigami's
"Could not create delegate for ToolBarLayout" lines came from a page action turning visible while the
header toolbar still built its buttons: keep a page's actions in place and change their text or
`enabled` instead, as the Watch tab's Disconnect/Connect does.) Mock switches for the states a healthy
mock never reaches: `MOCK_NO_WATCH=1` (paired, nothing connected), `MOCK_PAIR_PAUSE=bt|busy|slept`
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
- **The interface has eleven signals (`WatchesChanged`/`FirmwareProgress`/`LockerChanged`/
  `LanguageProgress`/`ExtensionsChanged`/`ExtensionStateChanged`/`CalendarsChanged`/`PluginsChanged`/
  `PermissionRequestsChanged`/`ConfigChanged`/`TaskChanged`) that augment polling — polling stays as the
  fallback.** (`TaskChanged(s kind, s status)` → the watch tasks above.)
  (`ConfigChanged(s key)` → `configChanged(key)`: the settings pages re-read, the cached schema is
  dropped, and `forwarding` follows notification.forward.) (`CalendarsChanged` → `refreshCalendars()`: the daemon
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
- The daemon is NOT D-Bus-activated. If the bus name is unowned → `DaemonPlaceholder` says why
  (`daemonState`), and where systemd can start it here offers "Start daemon": `systemctl --user
  reset-failed stoandl`, then `systemctl --user start stoandl` (the unit's `StartLimitBurst` refuses a
  plain start once tripped, silently from a button), and toasts a failed start with systemctl's own first
  stderr line (`daemonStartFailed`). In the Flatpak, without systemctl or without the unit it shows the
  command instead. Never assume it's up.
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
Reactive **signals** — `WatchesChanged()` (re-call ListWatches), `FirmwareProgress(s phase,
i percent, s detail)` (push flash progress, same phase vocabulary as `FirmwareStatus`),
`LockerChanged()` (re-call ListApps), `LanguageProgress(s phase, i percent, s detail)` (push
language-install progress, same phase vocabulary as `LanguageStatus`), `ExtensionsChanged()`
(re-call ExtList), `ExtensionStateChanged(s name, s state)` (the finer companion to
`ExtensionsChanged`: an unsolicited per-extension run-state transition — `state` ∈
`ready`/`exited`/`quarantined` — that the list-level poke can't catch, so a crashed/quarantined
extension shows live instead of a stale "running"), and `CalendarsChanged()` (re-call ListCalendars —
the daemon pokes it when an async sync adds/drops calendars after a source CRUD), `PluginsChanged()` /
`PermissionRequestsChanged()` (re-call PluginList / PermPending) and `ConfigChanged(s key)` (a
stoandl.conf key was written, by any client or the daemon: re-call GetConfig) — consumed on top of
polling (see Hard rules).
The GUI also consumes daemon-side hooks beyond the original 51 methods: `transport` on ListWatches +
`synced` on ListApps (#4); `GetSyncStatus` (#5; its 5th column `key` names the service's master key —
`SetSyncEnabled` is an alias for SetConfig of it, and the GUI no longer calls it); `ExtList.config` (and its 9th column, the last stderr line) +
`ExtConfigSchema`/`ExtGetConfig`/`ExtSetConfig` (#7); `GetHealthSummary`/`GetHealthSeries` (#8);
`SetWatchNickname` (#9); `GetConfigSchema` (16 columns) /`GetConfig`/`SetConfig` (#10), `Restart`,
`ListWatchPrefs` columns 8–10 (section, help, requires) and `ResetWatchPrefs`; `VoiceModels`' 9th column
`kind` (stt|tts), `TtsStatus`/`Speak`/`StopSpeaking`; a manifest field's optional `description`/`help`
in `ExtConfigSchema`; `WatchDetails`; notification
regex filters; the per-app app-name placement (`NotifSetAppName` + `NotifList`'s 7th column, the
override of `notification.app_name`; empty = follows it); a changelog URL on `CheckFirmware`; the watch
tasks (`TaskStatus`/`TaskChanged`, SideloadApp/TakeScreenshot/GatherLogs/GetCoreDump answering
`ok:started`); `NotifMuteAllStatus`; `NotifSetVibePattern`/`NotifVibeTest`; `Ping`; `Transcribe`;
`ListCalendarSources`' `lastError`/`lastSync` columns. All are
implemented in the mock (`tools/mock_stoandl.py`) and must be grown in the real Kotlin daemon to match.
(Notification quiet-hours hooks were dropped — superseded by the daemon's `dnd.sync`.)

## Not on D-Bus (shell out to the `stoandl` CLI, co-located): backup, restore, support bundle.

## Design reference
Target look/layout/states = the "KDE Kirigami by-the-book" prototype (`docs/stoandl KDE by-the-book.html`
→ `docs/kde-hig.jsx`). Match its FormCard grouping, page-action placement (header/footer toolbar, NOT a
FAB), passive-notification toasts, and danger-zone styling — in structure and density, taking colors
from the system theme.
