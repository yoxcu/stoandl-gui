# stoandl GUI — implementation handoff

A Kirigami (Plasma Mobile / convergent) front-end for the **stoandl** Pebble companion daemon.
This is the build spec for Claude Code on the dev machine. Pair it with:

- **`handoff/dbus-interface.md`** — the daemon's D-Bus contract (51 methods, the source of truth for every call below).
- **The visual prototype** — `stoandl Mobile UI.html`, "KDE · Kirigami by-the-book" artboard. That is the target look/layout/states. Open it in a browser; it's fully navigable.

> **One-line architecture:** a Qt6/Kirigami QML app + a thin C++ D-Bus client QObject, talking to
> `de.yoxcu.stoandl.Control` on the **session bus**. No JVM, no shared code with the daemon — it's
> just another client of the same interface the `stoandl` CLI uses. Builds musl-native on Alpine /
> postmarketOS (Qt is first-class there) and glibc on the desktop.

---

## 1. Stack & project shape

| Concern | Choice | Why |
|---|---|---|
| UI toolkit | **Kirigami** (Qt6 / QtQuick Controls) | The only path to genuine Breeze "by-the-book"; convergent phone↔desktop for free |
| Forms | **KirigamiAddons FormCard** (`org.kde.kirigamiaddons.formcard`) | `FormCard`, `FormHeader`, `FormButtonDelegate`, `FormSwitchDelegate`, `FormComboBoxDelegate` — these *are* the prototype's grouped rows |
| Navigation | **`Kirigami.NavigationTabBar`** in the window footer | KDE HIG: ≤5 destinations → tab bar, not a drawer. We have exactly 5 |
| D-Bus | **Thin C++ QObject** (`QDBusInterface`) exposed to QML | QML has no good native D-Bus; one `StoandlClient` shim wraps all 51 calls as `Q_INVOKABLE` + emits Qt signals from poll timers |
| Language | **QML for all UI**, C++ only for the D-Bus shim + parsing | Keeps Kotlin out of the GUI; QML is most of the code |
| Packaging | **APKBUILD** (phone, musl) first; optional **Flatpak** (KDE runtime) for the desktop | Build compiles per-arch; musl is a non-issue for Qt |

```
stoandl-gui/
├── CLAUDE.md                  # see §6 — paste into the repo root
├── src/
│   ├── main.cpp               # Kirigami app bootstrap
│   ├── StoandlClient.h/.cpp   # the D-Bus shim (§3)
│   └── RecordModels.h/.cpp    # QAbstractListModel per list (watches, apps, exts, …)
├── qml/
│   ├── main.qml               # ApplicationWindow + NavigationTabBar footer
│   ├── WatchPage.qml          # §4 screen 1
│   ├── HealthPage.qml         # screen 2 (steps/sleep/heart graphs)
│   ├── AppsPage.qml           # screen 3
│   ├── ExtensionsPage.qml     # screen 4
│   └── SettingsPage.qml       # screen 5 (sync + watch settings + firmware + system + diagnostics + reset)
├── packaging/APKBUILD
└── data/                      # desktop integration — installed by CMake (see data/README.md)
    ├── de.yoxcu.stoandl.gui.desktop
    ├── de.yoxcu.stoandl.gui.metainfo.xml    # AppStream (project_license GPL-3.0-only)
    └── icons/hicolor/**/apps/de.yoxcu.stoandl.gui.{png,svg}
```

> App ID is **`de.yoxcu.stoandl.gui`** (reverse-DNS of the `yoxcu.de` org domain, sibling of
> the daemon bus name `de.yoxcu.stoandl`) — not the `org.kde.*` template default. The desktop-file
> basename, the Wayland `app_id` (`setDesktopFileName`), and the icon name all share it.

---

## 2. The interface in one breath

- **Bus:** session · name `de.yoxcu.stoandl` · path `/de/yoxcu/stoandl` · iface `de.yoxcu.stoandl.Control`.
- **Not D-Bus-activated.** If the name is unowned, the daemon isn't running — the GUI must detect this
  (`org.freedesktop.DBus.NameHasOwner`) and show a "daemon not running" state with a
  `systemctl --user start stoandl` affordance. Don't assume it's up.
- **No signals, no properties — pure request/response.** Every "live update" is a re-poll. This is the
  central design constraint; §3 handles it in one place.
- **Return shapes:** either a status string `kind:message` (split on the **first** `:`), or `as` (array
  of records, **fields tab-separated**). Only 4 types exist: `s`, `b`, `as`, void.
- **Status `kind`s** to handle everywhere: `ok` `error` `notready` `notfound` `ambiguous` plus op-specific
  (`pending` `timeout` `inprogress` `reboot` `failed` `done` `uptodate` `disabled` `busy` `idle` `none`).
  **`notready`** = libpebble up but no watch / not ready → this is the GUI's "no watch connected" empty state.

---

## 3. `StoandlClient` — the one shim everything goes through

A single C++ QObject registered as a QML singleton. Three responsibilities: **call**, **parse**, **poll**.

```cpp
// Status string → { kind, tail, fields[] }   (tail split on '\t')
struct Status { QString kind; QString tail; QStringList fields; bool ok() const { return kind=="ok"; } };

class StoandlClient : public QObject {
  Q_OBJECT
  Q_PROPERTY(bool daemonUp READ daemonUp NOTIFY daemonUpChanged)
public:
  // generic
  Q_INVOKABLE Status   call(const QString &method, const QVariantList &args = {});   // s-returning
  Q_INVOKABLE QVariantList list(const QString &method, const QVariantList &args = {}); // as → [{f0,f1,…}]
  // typed wrappers (one per method in dbus-interface.md) e.g.:
  Q_INVOKABLE QVariantList listWatches();          // → rows {name,state,battery}
  Q_INVOKABLE Status connectWatch(const QString &name);   // Connect(s)
  Q_INVOKABLE Status pair();                        // Pair(); then startPolling("PairStatus", …)
  // …51 total

signals:
  void watchesChanged(QVariantList rows);     // emitted by the focus-poll timer (see below)
  void pairStatus(QString kind, QString msg); // emitted by the Pair poll timer
  void firmwareStatus(QString kind, int pct); // FirmwareStatus poll
  void languageStatus(QString kind, int pct); // LanguageStatus poll
  void daemonUpChanged();
};
```

### Polling model (because there are no signals)

| Poller | Source method | Cadence | Lifetime | Drives |
|---|---|---|---|---|
| **Focus poll** | `ListWatches` (+`Battery`) | 4 s | while app is foreground & a watch screen is visible | live connection state + battery on the Watch screen, post-reset reconnect |
| **List refresh** | `ListApps` / `ExtList` / `ListCalendars` | on screen show + **after every mutation** | — | Apps, Plugins, Sync lists (no `*Changed` signal yet) |
| **Pair** | `PairStatus` | 1.5 s | from `Pair()`/`Repair()` until `ok`/`error`/`timeout` (≤145 s) | pairing dialog |
| **Firmware** | `FirmwareStatus` | 0.8 s | from `UpdateFirmware()`/`SideloadFirmware()` until `reboot`/`failed` or post-activity `notready` (≤600 s) | flash progress bar |
| **Language** | `LanguageStatus` | 0.6 s | from `InstallLanguage()`/`SideloadLanguage()` until `done`/`failed` (≤180 s) | install progress bar |

> Match the CLI's poll loops exactly (cadence/timeout/terminal states are in `dbus-interface.md` →
> *Long-running operations*). The firmware/language "success = a `notready` seen **after** activity"
> rule matters — the watch reboots and the link drops; don't treat that as an error.
>
> **Golden rule:** after any mutating call (`RemoveApp`, `ExtEnable`, `SetCalendarEnabled`, …),
> **re-fetch that screen's list**. There is no change notification.

---

## 4. Screen-by-screen build spec

Each screen is a `Kirigami.ScrollablePage` whose content is FormCards. Navigation is a
`Kirigami.NavigationTabBar`. **Per the KDE HIG ([layout_and_nav](https://develop.kde.org/hig/layout_and_nav/)),
the tab bar is responsive: BELOW the content on mobile/narrow, ABOVE the content on desktop/widescreen.**
So `main.qml`: put the NavigationTabBar in the window **footer**; in desktop mode it moves to the top.
Do **not** use a sidebar/GlobalDrawer for navigation here — that's the >5-destinations pattern; we have 5.
Tab order **must** start with the launch view (Watch). Icons in parens are Breeze icon names.

**Verified-correct reference render:** `stoandl KDE by-the-book.html` (mobile + desktop, HIG-checked).
Match it: mobile = header actions + bottom tab bar; desktop = top tab bar + section title/actions toolbar
+ **centered, width-constrained content** (~`gridUnit*40` max, don't let FormCards stretch full-width).

**Spacing — use the Kirigami unit scale (HIG), not magic px:** `largeSpacing` between groups/cards,
`smallSpacing` within a group, `largeSpacing` page-edge padding (0 for frameless container views),
`gridUnit` (18px) for fixed sizes, `IconSizes.medium` for list items *with* subtitles,
`IconSizes.smallMedium` for those without.

#### §4-0 · Shared page chrome & action placement (READ FIRST — this is the thing that's been drifting)

Every screen follows the **same** action model. Getting this right is what makes the build match the
KDE conventions; getting it wrong means hand-placed header buttons that fight the framework.

**Page actions** — declare on the `Kirigami.ScrollablePage` `actions` (Kirigami's form-factor-aware
action system). Do **not** hand-place buttons in the header.
- **Primary "create/add" action.** Wire it as a page action (`actions.main` / a single `Kirigami.Action`).
  Kirigami renders page actions **in the header (right side) in desktop mode, and in a bottom FOOTER
  TOOLBAR in mobile mode** — this is the official, by-the-book behavior
  ([develop.kde.org](https://develop.kde.org/docs/getting-started/kirigami/introduction-actions/)).
  **There is NO Material-style round floating circle.** The old draggable `ActionButton` is legacy;
  current Kirigami uses the footer toolbar. The mockup's bottom-right round FAB is a Material idiom —
  **ignore it; the footer toolbar IS the correct KDE rendering.** When you flip to mobile mode and the
  action "moves to the bottom," that's success, not a bug.
- **Mobile vs desktop = `Kirigami.Settings.isMobile`**, decided by PLATFORM/INPUT (touch or env flag),
  **NOT window size** (unlike libadwaita — shrinking the desktop window does nothing). Preview on the
  dev box with `QT_QUICK_CONTROLS_MOBILE=1` (or `PLASMA_PLATFORM=phone:handset`); the phone sets it
  automatically.
- **Secondary actions** (refresh/sync-now, search) → also page `actions` or `contextualActions`; they
  share the same header(desktop)/footer(mobile) toolbar. Order them after the primary.
- **Page overflow (kebab)** → use `Kirigami.ActionMenu` only for *row-level* menus; page-level extras
  go in `contextualActions` and Kirigami handles the overflow.

**Per-screen primary action** (renders in header on desktop, footer toolbar on mobile — never a round FAB):

| Screen | Primary action | Secondary actions |
|---|---|---|
| Watch | **Pair new watch** | Ring watch, Sync now |
| Health | none (read-only graphs) | (date-range, later) |
| Apps & Faces | **Install .pbw** / **Install extension** (depends on segment) | Sync now |
| Notifications | **Add filter** | — |
| Settings | none (inline actions in FormCards) | Sync all now |

> **Nav restructure (current):** 5 tabs = **Watch · Health · Apps · Notifications · Settings**. Extensions
> folded into **Apps** as a 3rd segment (Faces / Apps / Extensions — all "installed things"); the freed
> slot became a first-class **Notifications** screen (mute/temp-mute/per-app/quiet-hours/regex filters,
> too much for a Settings row). Sync services live in Settings. Still 5 → NavigationTabBar holds. Launch
> view (Watch) first. The Apps install action is segment-aware (`Install .pbw` for faces/apps,
> `Install extension` for the Extensions segment).

> If a screen has no primary "add" action (Health, Settings), that's fine — its actions live inline in the
> FormCards. Don't invent a corner button.

**Header:** the title comes free from the page; the action toolbar Kirigami builds from `actions` is the
only header chrome. No hand-rolled header buttons.

### Screen 1 · Watch  (`smartwatch-symbolic`)

| UI element (prototype) | Kirigami | D-Bus | Notes |
|---|---|---|---|
| Firmware-update banner | `Kirigami.InlineMessage` (top of page, only when update exists) | `CheckFirmware` | title "PebbleOS X.Y.Z available"; actions **Update now** (triggers `UpdateFirmware` → poll `FirmwareStatus` inline — no detour to Settings) and **What’s new** (`xdg-open` `firmware.changelogUrl`). |
| Active-watch hero card (name, model, conn chip, battery) — **tappable** | custom `FormCard`, clickable, trailing chevron | `ListWatches` (the `connected` row) + `Battery` | **tap opens the Watch details dialog** (below). No separate HARDWARE list — the hero replaces it. |
| Known-watches list | `FormCard` + `FormButtonDelegate` ×N | `ListWatches` rows `{name,state,battery}` | trailing: "active" chip if connected, else **Connect** → `Connect(name)` |
| Per-watch overflow (kebab) | `Kirigami.ActionMenu` (popup desktop / bottom sheet mobile) | `Repair(name)` · `Unpair(name)` | menu: **Re-pair** · **Rename…** · **Forget watch** (destructive, red) → confirm dialog. `Unpair("")` = forget all. |
| **Pair new watch** (primary action) | page action → header (desktop) / footer toolbar (mobile), §4-0 → `Kirigami.PromptDialog` | `Pair()` → poll `PairStatus` | icon **`list-add`** (`+`), consistent with Install/Add across screens. Dialog: "confirm the 6-digit code **on the watch**"; close on `ok`/`error`/`timeout`. |
| Ring watch | page/contextual action (§4-0) | `FindWatch()` (`b`) | secondary |
| Sync now | page/contextual action | re-poll `ListWatches` | secondary |

**Dropped from the original design:** the inline **HARDWARE** list and the standalone **Firmware** row —
both duplicated the hero card / now live in the firmware banner + details dialog. Don't re-add them.

#### §4d · Watch details dialog (tap the connected-watch card)

A dialog (bottom sheet on mobile, popup on desktop). Top: watch glyph + name·code + Connected. Then the
hardware facts as label/value rows, then an action list:

| Section | Source | Notes |
|---|---|---|
| Details rows | `WatchInfoText()` parsed, or `ListWatches`+`Battery` | Model, Platform, Transport, Firmware, **Serial**, Board, Battery, Last sync (Serial/Board monospaced) |
| Developer connection | dev-mode/PKJS listen | starts the developer connection (for `pebble install --phone`/SDK). Confirm exact daemon call. |
| Capture screenshot | `TakeScreenshot(absPath)` | |
| Check for updates | `CheckFirmware` | |
| **Language** (tappable row → picker) | `ListLanguages` / `InstallLanguage(locale)`/`SideloadLanguage` (+poll `LanguageStatus`) | watch-specific — lives here, not in Settings. Tapping opens a sub-view list of languages; selecting one loads it onto the watch. Current is marked. |
| Firmware row → **What’s new** link | `xdg-open` `firmware.changelogUrl` | **permanent** link next to the firmware number (not just on update). |
| Rename… | **⚠ no daemon method today** | flagged; needs a new `RenameWatch`/`SetWatchName` hook (§5). Show it, but it's non-functional until the hook lands — confirm whether stoandl supports renaming. |
| **Debug…** (submenu, chevron) | — | opens a second-level view: **Core dump** · **Pull watch logs** (`GatherLogs`) · **Support bundle** (`stoandl support`) · **Reboot to recovery (PRF)** (`ResetIntoRecovery`) · **Write notification** (disabled, `SOON`) · **Factory reset** (`FactoryReset`, red). All low-level/diagnostic/recovery tools live here. |
| Forget watch (red) | `Unpair(name)` | → confirm dialog |
| **Firmware-update notice** | `Kirigami.InlineMessage` (info, at top of page) | `CheckFirmware` result | shown only when an update exists: title "PebbleOS X.Y.Z available", actions **View update** (→ navigate to System tab / firmware card) and **What’s new** (`xdg-open` the PebbleOS changelog URL from `firmware.changelogUrl`, e.g. `ndocs.repebble.com/PebbleOS-Changelog-…`). The Hardware→Firmware row also routes to System and shows "→ X.Y.Z available" when applicable. |

**Today's limits (wire later):** no transport (BLE/Classic) badge, no live battery/charging — battery
& state refresh on the 4 s focus poll. Charging state is **unavailable** (hardware), don't design for it.

### Screen 2 · Apps & Faces  (`view-list-icons-symbolic`)

| UI element | Kirigami | D-Bus | Notes |
|---|---|---|---|
| Watchfaces / Apps split | **segmented button group** (Kirigami button-group / inline tabs) switching one list at a time | `ListApps` rows `{uuid,type,order,flags,title,developer}` | filter by `type`; matches the prototype. HIG-clean (selectable button group for switching views of like content). *Earlier draft recommended two stacked sections — overruled: toggle is the chosen design and equally HIG-valid.* |
| Row | `FormButtonDelegate` | — | leading icon; title = `title`; subtitle = `developer`/`uuid` |
| Flag chips | inline `Kirigami.Chip`s | `flags` ⊆ `active,config,system` | `active` = current face. **`sideloaded` is NOT shown** — stoandl sideloads everything, so the mark is noise. |
| Row overflow (kebab) | `Kirigami.ActionMenu` (popup desktop / bottom sheet mobile) | `LaunchApp` · set-active · `OpenConfig` · `RemoveApp` | **flag-aware menu** — see §4c. |
| **Install .pbw** (primary action) | page action → header (desktop) / footer toolbar (mobile), §4-0 | `SideloadApp(absPath)` | icon **`list-add`** (`+`) — same as Pair/Add (NOT a download glyph; keep all add-actions consistent). Absolute daemon-side path. |
| Clay/PKJS config | **`xdg-open` the URL** | `OpenConfig(app)` → URL | stoandl serves config from its own embedded **HTTP server**; the page returns settings to that server directly. GUI just `xdg-open`s the URL. **No webview, no scheme handler, no QtWebEngine.** See §4a. |

After `SideloadApp`/`RemoveApp`, re-call `ListApps`. `synced` flag isn't emitted yet (gap).

#### §4a · Clay/PKJS config — stoandl's own HTTP server (just open the URL)

The daemon does all the work. The GUI's entire responsibility is: take the URL from
`OpenConfig(app)` and `xdg-open` it. That's it.

**Mechanism** (daemon-side; the GUI doesn't implement any of it): stoandl runs an **embedded HTTP
server**. `OpenConfig` returns an `http://…` URL on that server with the config page's `return_to`
pointing back at the same server. On **Save**, the page submits the settings straight to stoandl's
endpoint over HTTP — the daemon receives them and pushes to the watch. No URL-scheme interception, no
`.desktop` handler, no per-browser logic. **Confirmed: works in any browser and from another device
over the LAN**, because it's a plain networked web server.

**GUI implications — all simplifications:**
- The Apps row's **Configure** action (shown only when the `config` flag is set) = `xdg-open <url>`
  where `<url>` is `OpenConfig(app)`'s return. One line.
- **No QtWebEngine, no scheme handler, no `.desktop`, no packaging caveats.** Drop all of it.
- `WebviewClose(json)` is irrelevant to the GUI (legacy/daemon-internal). Ignore it.
- After the user finishes in the browser there's no completion signal → re-poll `ListApps` when the
  Apps screen regains focus, in case the config changed the active face/title.

> Drift history: I twice guessed wrong here (embedded webview → scheme handler). Dev confirms it's an
> HTTP server and `xdg-open` is the whole GUI story. Net: the GUI just opens a URL; everything hard
> lives in the daemon. ("Configure from another device over LAN" works but was judged not worth a
> dedicated UI — plain `xdg-open` only.)

> **§4c · Apps & Faces row actions — INLINE, not a kebab.** Use the Kirigami `SwipeListItem` pattern:
> inline action buttons on each list delegate (shown on hover with a mouse, swipe-to-reveal on touch).
> No overflow menu — it's cleaner and more KDE-native here.
>
> - **Tap the row = launch.** For a **watchface**, launch *is* set-active (they're the same op) — so
>   there's no separate "Set as active" item. For an **app**, tap just runs it. Maps to `LaunchApp(uuid)`.
> - **Gear icon** (trailing, only if `config` flag) → `OpenConfig(app)` → `xdg-open` (§4a).
> - **Bin icon** (trailing, only if **not** `system`) → `RemoveApp(uuid)` → confirm dialog
>   ("Remove X? You can reinstall it later"). This removes from the **locker**.
>
> System apps show neither bin (unremovable) nor gear unless configurable. The `active` face shows the
> star/active indicator. **Note:** stoandl has no "remove from watch but keep in locker" concept — the
> locker is the synced set, so the bin = `RemoveApp`. If a watch-slot vs locker distinction is ever
> exposed, revisit. Stop the inline buttons' clicks from bubbling to the row's launch handler.

### Screen 3 · Extensions  (`plugins-symbolic`)

> **Naming — use "Extensions" everywhere.** The tab, page title, and section header are all
> **Extensions** (the daemon API is `Ext*`, so that's the canonical noun). Do **not** mix in "Plugins"
> or "Companion apps" as the label — "host-side companion" may appear once in descriptive body text, but
> the noun the user sees is always *Extension*.

| UI element | Kirigami | D-Bus | Notes |
|---|---|---|---|
| Extension row | `FormSwitchDelegate` + **inline** gear + bin (no kebab) | `ExtList` rows `{name,installed,enabled,config}` | toggle = enabled → `ExtEnable`/`ExtDisable`. Gear (if `config`) → `ExtOpenConfig`/§4b. Bin → `ExtUninstall(name, keepConfig)` + confirm. |
| Running indicator | *dropped* | — | **RUN badge removed** (toggle shows enabled). **Restart removed** (toggle off→on restarts). To show *crashed-but-enabled* later, use a small status dot. |
| **No kebab** | inline actions only (see row above) | | consistent with Apps/Faces |
|  • Configure… | menu item (only if `config != none`) | `ExtOpenConfig(name)` → `xdg-open`, OR schema methods (§4b) | |
|  • Restart / Start | menu item | `ExtRestart(name)` | label = Restart if running, else Start |
|  • Uninstall (red) | menu item | `ExtUninstall(name, keepConfig)` | → confirm dialog; default keeps config (offer a "keep config" checkbox → the `keepConfig` bool) |
| **Install extension** (primary action) | page action → header (desktop) / footer toolbar (mobile), §4-0 → `FileDialog` | `ExtInstall(absArchivePath)` | icon **`list-add`** (`+`), same as Pair/Install. `.tar.gz/.tgz/.tar/.zip`. |

Re-poll `ExtList` after each action. Richer run-states (quarantined/needs-config) aren't exposed yet (gap).

#### §4b · Extension settings — unified "Configure" action, two backends

Extensions need per-extension config (Matrix homeserver+token, Signal linking, SMS-bridge modem, sync
intervals). The daemon exposes **none of this yet** — these are hooks to add (§5). Design so the GUI
has **one** Configure affordance that fans out to two backends, chosen per-extension via a new
`config` field on `ExtList`:

`config ∈ { none | url | schema }`

- **`url` — web config (mirrors watchface config, recommended default).** `ExtOpenConfig(name)` returns
  an HTTP URL on stoandl's existing embedded server; GUI just `xdg-open`s it. Zero new GUI code, reuses
  the §4a infra, language-agnostic for extension authors. Best for anything with login flows, OAuth,
  QR-linking (Signal/Matrix), or non-trivial UI.
- **`schema` — native in-app form.** Extension ships a small typed manifest; daemon serves
  `ExtConfigSchema(name) → json`, `ExtGetConfig(name) → json`, `ExtSetConfig(name, json)`. GUI renders
  it dynamically as a `FormCard` of `FormSwitchDelegate` / `FormTextFieldDelegate` /
  `FormComboBoxDelegate` / `FormSpinBoxDelegate`, pushed as a `Kirigami.Page` with a Save action. Best
  for simple key-value settings (a homeserver string + an interval int reads far nicer as a native
  form than a web page). Field type → delegate mapping:
  `bool→Switch`, `string→TextField` (`secret:true`→`echoMode: Password`), `enum→ComboBox`,
  `int→SpinBox`.
- **`none`** → no Configure action shown.

**Recommendation:** ship **`url`** first (it's `xdg-open`, you already have the server) so every
extension can have settings immediately; add the **`schema`** renderer later for the simple-settings
extensions where a browser trip feels heavy. The GUI presents both identically — a single "Configure"
menu item — so the extension author picks the backend without the GUI caring.

> Drift note: the `config` field + `ExtOpenConfig` (and optionally the schema trio) are **new daemon
> methods** — see §5. Until they land, the Plugins screen ships enable/disable/restart/install/uninstall
> only (fully functional), with no Configure action. Don't fake settings UI.

### Screen 4 · Notifications  (`notifications-symbolic`)  — NEW

The reason Notifications got its own screen: too much config for a Settings row (mute, temp-mute,
per-app vibration/icon/priority, quiet hours, regex filtering). All native (fixed option sets).

| Section | Content | Notes |
|---|---|---|
| Master | **Forward notifications** toggle + **Mute temporarily** (30 min / 1 hr / Today) | global on/off + snooze |
| Per-app list | each app: on/off toggle + tap row → **deeper per-app view** | subtitle shows vibration or muted state |
| Per-app deeper view | back header; Notifications toggle + **Mute temporarily**; **Vibration** pattern picker (radio list, fixed set); **Custom icon**; **Allow during quiet hours** (priority override) | native form — the "fixed number of things to choose from" |
| Quiet hours | **Scheduled** (from–to toggle) + **Quiet now** temporary (1 hr / Morning) | both scheduled and on-demand quiet |
| Filters | regex rules with allow/block + **Add regex filter** | runs on title+body; block hides, allow overrides quiet hours |

> Maps to stoandl's notification-forwarding + filtering config. Per-app vibration/icon/priority and
> quiet-hours need daemon config keys — confirm which exist vs are hooks. Drift-report specifics.

### Screen 2 · Health  (`heart-symbolic`)  — NEW, read-only graphs

Like the original Pebble app's Health: steps / sleep / heart-rate with trends. Data comes from the
watch's activity sync. Charts are simple SVG (bars + area) themed with `Kirigami.Theme` colors.

| Card | Content | D-Bus | Notes |
|---|---|---|---|
| Today summary | step-goal ring + today's steps/goal + distance/calories/active tiles | health activity data (steps/distance/cal) | `SyncHealth` forces a refresh |
| Steps · this week | 7-bar weekly chart w/ goal line + daily-avg + trend vs last week | weekly steps series | |
| Sleep · last night | total + stacked deep/light/REM bar + legend + weekly avg + trend | sleep stages | |
| Heart rate | resting + current bpm + 24h area sparkline + min/max | HR series | **HR may not be exposed yet** — confirm; if absent, hide the HR card (don't fake). |

> Health requires the daemon to expose activity series (steps/sleep/HR) over D-Bus — today only
> `SyncHealth` (force a sync) exists. Reading the series back is a **hook** (§5). Until then, the Health
> screen can show the force-sync + last-synced state and an empty-until-synced message. Flag in drift report.

### Screen 3 · Apps & Faces  — (unchanged; see above, now tab 3)

### Screen 4 · Extensions  — (unchanged; see above, now tab 4)

### Screen 5 · Settings  (`settings-configure-symbolic`)  — Sync + System merged

**Sync was folded in here** ("it's all settings"). One scrollable page, FormCard groups in order:
**Sync services · Watch settings · Backup**. Header action: **Sync all now**. Firmware, diagnostics,
language, and danger-zone actions were **moved out**: firmware → the Watch banner (+ details dialog's
"What's new"); language → the Watch details dialog (watch-specific); logs/support bundle/core dump/
reboot-PRF/factory-reset → the Watch details **Debug** submenu. Settings is just genuine settings now.

| Group | Kirigami | D-Bus | Notes |
|---|---|---|---|
| Sync services | `FormCard` + per-service rows | `SyncWeather`/`SyncCalendar`/`SyncHealth` force-sync; `ListCalendars`+`SetCalendarEnabled` | per-service **master ON/OFF** needs `SetSyncEnabled`/`GetSyncStatus` (§5) — until then show force-sync + calendar toggles. **Don't fake.** |
| Watch settings | `FormCard` | quick-launch up/down, backlight, motion backlight, ambient slider | maps to watch config calls |
| Backup | `FormCard` | Backup/Restore = **shell out to `stoandl` CLI** | not on D-Bus |

---

## 5. Daemon hooks — what to add, in priority order

The GUI **ships and works on all 51 current methods via polling.** These daemon-side additions
(verbatim from `dbus-interface.md` → *hooks worth adding first*) upgrade it from polled to reactive
and unblock the two gaps above. Most are **wiring-only** (the libpebble3 `StateFlow`s already exist).

1. **`WatchStateChanged(s name, s state, i battery)`** signal — kills the 4 s focus poll; live list/battery + post-reset reconnect. *wiring-only*
2. **`FirmwareProgress` / `LanguageProgress`** signals — replace the flash/install poll loops. *wiring-only*
3. **`LockerChanged()` + `ExtensionStateChanged(s,s)`** — live Apps & Plugins. *wiring-only*
4. **Dropped fields:** add `transport` to `ListWatches`, `synced` to `ListApps` flags. *one line each*
5. **`GetSyncStatus() → as` + `SetSyncEnabled(s,b)`** — unblocks Screen 4's master toggles & last-sync labels. *reading = wiring-only; runtime start/stop of Koin-bound music/calendar = design work*
6. **Byte-returning variants** (`TakeScreenshotBytes`, `GatherLogsText`, `BackupTo`/`RestoreFrom`, `SupportBundle`) — **only** needed if the GUI is ever **not co-located** with the daemon. A same-host phone GUI doesn't need these; skip until there's a remote use case.
7. **Extension config** (§4b): add a `config` field (`none|url|schema`) to `ExtList` + `ExtOpenConfig(name) → s`. Optionally the schema trio `ExtConfigSchema`/`ExtGetConfig`/`ExtSetConfig` for native forms. *`url` variant = reuse the existing HTTP config server, low effort; schema = more work, defer*
8. **Health activity series** (Screen 2): expose steps/sleep/heart-rate series + today totals over D-Bus (today only `SyncHealth` forces a sync; no read-back). Without it the Health graphs can't populate. *new methods, e.g. `GetHealthSummary`/`GetHealthSeries`*
9. **Rename watch** (§4d details dialog): no `RenameWatch`/`SetWatchName` method exists. Add one if stoandl can set a watch's display name; otherwise drop the Rename action. *confirm feasibility first*
10. **Daemon config over D-Bus** (Settings → Advanced): everything in `stoandl.conf` that isn't watch-specific (units, weather provider, auto-reconnect, timeline window, log level, …) is **not exposed** today — editable only by hand-editing the conf. Add a **schema-driven** surface: `GetConfigSchema() → as` (key, type, label, options), `GetConfig()`/`SetConfig(key, value)`. The GUI renders it generically as FormCard rows (toggle/combo/number), so new conf keys appear automatically. *Mirrors the extension `schema` backend (§4b) — same generic renderer.*

Idiomatic implementation: expose list/status as `org.freedesktop.DBus.Properties` so standard
`PropertiesChanged` fires — but plain custom signals match the dbus-java machinery already in the daemon.

**Build order suggestion:** ship v1 GUI on polling (screens 1–3 + 5 fully, screen 4 in force-sync
tier) → add hooks #1–3 (biggest UX win, pure wiring) → add #4 → tackle #5 for the full Sync screen.

---

## 6. CLAUDE.md for the GUI repo

Paste this into `stoandl-gui/CLAUDE.md`:

```markdown
# stoandl-gui

Kirigami (Qt6/QML) front-end for the stoandl Pebble daemon. Convergent: Plasma Mobile + desktop.

## Architecture
- QML UI (Kirigami + KirigamiAddons FormCard) + one C++ shim `StoandlClient` (QDBusInterface).
- Talks to `de.yoxcu.stoandl.Control`, session bus, path `/de/yoxcu/stoandl`. Full contract:
  `docs/dbus-interface.md`. No code shared with the daemon — we are just another client.
- Builds musl-native (Alpine/postmarketOS) and glibc (desktop). No JVM.

## Hard rules
- **The interface has NO signals/properties.** Every live value is polled. All polling lives in
  `StoandlClient` (focus poll 4s for ListWatches; op pollers for Pair/Firmware/Language at the
  CLI cadences). UI never polls directly.
- **After any mutating call, re-fetch that screen's list.** There is no change event.
- Returns are either `kind:message` (split on first `:`) or tab-separated `as` records. Parse in
  `StoandlClient`, never in QML. Handle `notready` as the "no watch / not ready" empty state.
- The daemon is NOT D-Bus-activated. If the bus name is unowned → show "daemon not running", offer
  `systemctl --user start stoandl`. Never assume it's up.
- 5 destinations → `Kirigami.NavigationTabBar` (KDE HIG). Launch view (Watch) is tab 0. **Responsive:
  bottom on mobile, top on desktop** (put it in the window footer; it relocates in desktop mode). NOT a
  sidebar — that's the >5 pattern. Desktop content is **centered & width-constrained**, not full-bleed.
- Paths passed to SideloadApp/SideloadFirmware/etc. are **absolute, daemon-side**.
- **Actions go on the page `actions`, never hand-placed header buttons.** Kirigami renders page actions
  **in the header (desktop) and in a bottom footer toolbar (mobile)** — this is by-the-book. There is
  **NO round floating FAB**; the old draggable ActionButton is legacy. When mobile mode moves the action
  to the bottom, that's correct. **Mobile vs desktop = `Kirigami.Settings.isMobile` (platform/input),
  NOT window size** — resizing won't reflow it (unlike libadwaita). Preview phone layout with
  `QT_QUICK_CONTROLS_MOBILE=1`. Per-screen action list in handoff §4-0; Sync & System have no page
  action (inline FormCard actions). Don't build a custom Material FAB to match the mockup — the mockup's
  round button is a Material idiom, not the KDE pattern.
- **Never hardcode colors or fonts.** Use `Kirigami.Theme` roles (`backgroundColor`, `textColor`,
  `highlightColor`, …) and `Kirigami.Units` for spacing (`largeSpacing` between groups, `smallSpacing`
  within, `gridUnit`/`IconSizes.*` for sizes — per HIG). The app inherits the system color scheme at
  runtime; the prototype's dark hexes are a **layout/density spec, not a color spec**. Hardcoding to
  match the mockup breaks light/dark/accent adaptation.

## Status kinds
ok · error · notready · notfound · ambiguous · pending · timeout · inprogress · reboot · failed ·
done · uptodate · disabled · busy · idle · none

## Not on D-Bus (shell out to the `stoandl` CLI, co-located): backup, restore, support bundle.
## Blocked until daemon hooks: per-service master sync toggles (need SetSyncEnabled/GetSyncStatus).

## Design reference
Target look/layout/states = the "KDE Kirigami by-the-book" prototype (HTML). Match its FormCard
grouping, passive-notification toasts, and danger-zone styling — in **structure and density**, taking
**colors from the system theme**. **Exception: the prototype's bottom-right round "+" FAB is a Material
idiom, NOT the KDE pattern** — use Kirigami page actions (header on desktop / footer toolbar on mobile)
instead. When the prototype and KDE convention disagree, KDE convention wins.

## Developing on a non-Plasma desktop (GNOME/other)
Kirigami pulls colors from KDE's Qt integration at runtime, which a GNOME box lacks — so the app looks
flat/light there. That's an **environment gap, not a styling bug; do NOT hardcode colors to "fix" it.**
- Need `qqc2-desktop-style` + `breeze-icons` installed (no need for `plasma-integration`, which drags
  in KDE apps).
- Run with `QT_QUICK_CONTROLS_STYLE=org.kde.desktop`.
- For a dark **Breeze Dark** preview without installing KDE apps, merge the `[Colors:*]` groups from
  `docs/handoff/BreezeDark-dev-preview.kdeglobals` into `~/.config/kdeglobals` (`KColorScheme` reads
  them directly). On the real phone the scheme is supplied by Plasma Mobile.
```

---

## 7. Packaging notes

- **Phone (postmarketOS, aarch64/musl):** `APKBUILD` depending on `qt6-qtbase qt6-qtdeclarative
  kirigami kirigami-addons`. Qt builds/links musl-native — no glibc anywhere. This is the idiomatic
  Plasma Mobile path.
- **Desktop (x86/glibc):** same source; ship a distro package or a **Flatpak** on the
  `org.kde.Platform` runtime (one build def, runs on the phone too via the glibc-in-sandbox runtime).
- Register the session-bus name in the `.desktop` + provide an AppStream `.metainfo.xml`.
- The GUI does **not** package the daemon — it's a separate systemd/OpenRC user service. Document the
  dependency and the "start the daemon" affordance instead of bundling it.
```

---

## 8. Drift report template (Code → design loop)

After each milestone, Code reports back in this format. Paste it to the design side (the prototype +
this doc get patched so the three sources never disagree). Keep it terse; only report *deltas*.

```
## Drift report — Milestone N (screen: …)

### D-Bus contract deltas (vs docs/handoff/dbus-interface.md)
- <Method>: doc says <X>, daemon actually <Y>. (e.g. "ListWatches returns 4 tab
  fields {name,state,battery,transport}, doc lists 3" — or "Connect returns
  'pending:' not 'ok:' on first call")
- Return-shape / status-kind surprises (a kind not in the documented set; a
  record field order mismatch; empty vs notready ambiguity).
- Long-running ops: actual cadence/terminal states vs documented poll loop.

### Missing daemon surface (blocks or degrades a screen)
- <Screen> needs <data/action> that no D-Bus method exposes. Maps to hook #__ in
  §5, or is new. (e.g. "Plugins: no `config` field on ExtList yet → no Configure
  action shipped")

### UX / layout findings on real device
- Anything that felt wrong on actual Plasma Mobile (touch targets, the segmented
  toggle, footer toolbar crowding, a flow that needs a state the prototype doesn't
  show).
- Screens where the prototype and KDE convention conflicted, and which you followed.

### Decisions taken / assumptions made
- Anything you had to decide because the docs were silent — so it can be ratified
  or corrected.

### Screenshots
- One per screen at mobile width (QT_QUICK_CONTROLS_MOBILE=1) + dark scheme.
```

The design side responds by: patching `dbus-interface.md` for signature drift, updating the prototype
+ §4 for UX changes, and moving anything blocking into §5 as a prioritized hook. That keeps prototype
↔ handoff ↔ build in sync.
