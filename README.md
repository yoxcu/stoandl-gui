<p align="center"><img src="data/icons/hicolor/256x256/apps/de.yoxcu.stoandl.gui.png" alt="stoandl-gui" width="120"></p>

# stoandl-gui

Kirigami (Qt6 / QML) front-end for the **stoandl** Pebble companion daemon.
Convergent: Plasma Mobile + desktop. See `CLAUDE.md` and `docs/handoff/` for the
full spec, the D-Bus contract, and the visual prototype.

## Screenshots

<table>
  <tr>
    <td align="center" width="50%"><img src="docs/screenshots/watch.png" width="260" alt="Watch tab"><br><sub><b>Watch</b> — pairing, firmware, battery</sub></td>
    <td align="center" width="50%"><img src="docs/screenshots/battery.png" width="260" alt="Battery insights"><br><sub><b>Battery insights</b> — charge, drain, power</sub></td>
  </tr>
  <tr>
    <td align="center" width="50%"><img src="docs/screenshots/health.png" width="260" alt="Health tab"><br><sub><b>Health</b> — steps, sleep, heart rate</sub></td>
    <td align="center" width="50%"><img src="docs/screenshots/apps.png" width="260" alt="Apps tab"><br><sub><b>Apps</b> — faces, apps, extensions</sub></td>
  </tr>
</table>

## Status

`StoandlClient` (C++ QML singleton) is the only thing that touches D-Bus: generic
`call`/`list`, typed wrappers (one per method, parsing every tab-record and status
string), `daemonUp` via `NameHasOwner` (+ reactive `NameOwnerChanged`), and all
polling. Shared QML: `StatusChip`, `DaemonPlaceholder`. `Kirigami.ApplicationWindow`
+ a `Kirigami.NavigationTabBar` footer (responsive: bottom on mobile, top on
desktop) with five destinations — **Watch · Health · Apps · Alerts ·
Settings** — and **Watch is tab 0**. The nav hides when the daemon is down.
(The notifications tab is labelled **Alerts** — short enough not to wrap on narrow widths.)

- **Watch** — firmware-update `InlineMessage` banner (Update now flashes inline via
  the `FirmwareStatus` poll; What's new opens the PebbleOS changelog), a tappable
  active-watch hero card → **Watch details dialog** (Model/Platform/Transport/
  Firmware+What's-new/Serial/Battery/Last-sync, a Developer-connection toggle, a
  Language picker, a Rename pencil, a **Debug** submenu — core dump · pull logs ·
  support bundle · reboot-to-recovery · write-notification [SOON] · factory reset —
  and Forget watch), and a known-watches list with inline Connect/active + forget
  (no kebab). Pair / Ring / Sync-now as page actions. A **Battery insights** row
  opens a sub-page: current % with a charging/voltage/time-left hero + gauge, a
  battery-%-over-time Canvas chart with a 24 h / 7 days / 30 days switcher (with a
  faint **notification-density** overlay marking busy hours), a per-hour **drain**
  bar chart, a **What drew power** donut + legend (an *estimated* usage share —
  display / vibration / speaker / heart-rate / Bluetooth / CPU), and trend tiles
  (discharge rate, charges·7d, last charged, 24 h range) — the local equivalent of
  the official app's Battery screen, from `BatteryInsights`/`BatteryHistory`/
  `BatteryActivity`/`BatteryPower`. 4 s `ListWatches` focus poll; 1.5 s / 145 s `PairStatus` poll.
- **Health** — read-only steps / sleep / heart-rate cards (step-goal ring, weekly
  bars, stacked sleep bar, 24 h heart sparkline — Canvas-drawn, theme-colored) from
  `GetHealthSummary`/`GetHealthSeries`. The heart card hides when HR isn't available;
  a "Sync health" action forces a sync.
- **Apps & Faces** — a 3-segment switch (Faces / Apps / Extensions). Faces/Apps:
  tap = launch (= set-active for a face), inline gear (if `config`) + bin (if not
  `system`); the sideloaded chip is dropped. Extensions: enable/disable switch +
  inline gear (web config via `xdg-open`, or a native form rendered from
  `ExtConfigSchema`/`ExtGetConfig`/`ExtSetConfig`) + bin (uninstall, keep-config
  option). Install action is segment-aware (`.pbw` vs extension archive).
- **Alerts** (notifications) — Forward-notifications master toggle + Mute-temporarily;
  per-app list → a deeper per-app dialog (mute, vibration pattern, custom icon);
  regex Filters (allow/block, Add-filter page action). Maps to `NotifList`/
  `NotifSetMute`/`NotifSetMuteAll`/`NotifSetStyle` + the filter hooks. (Quiet hours
  is intentionally absent — it is superseded by the daemon's `dnd.sync`, which
  mirrors desktop Do Not Disturb ↔ the watch's native Quiet Time.)
- **Settings** — Sync services (per-service master toggles via `GetSyncStatus`/
  `SetSyncEnabled` + force-sync), **Calendars** (add/edit/remove calendar *sources* via
  `ListCalendarSources`/`AddCalendarSource`/`UpdateCalendarSource`/`RemoveCalendarSource` —
  a CalDAV account's discovered calendars nest under it with per-calendar enable toggles;
  the password field is **write-only**, the daemon stores it in the keyring/0600-file and
  never returns it; updated live via the `CalendarsChanged` signal), Watch settings (from
  `ListWatchPrefs`/`SetWatchPref`), Backup (CLI shell-outs), and a schema-driven
  **Advanced** group that renders `stoandl.conf` generically from `GetConfigSchema`/
  `GetConfig`/`SetConfig`, so new config keys appear automatically.

The daemon-side additions these screens rely on are catalogued in
`docs/handoff/drift-report.md` and implemented in the mock (`tools/mock_stoandl.py`).

## Build

Requires Qt6 (Core/Gui/Widgets/Qml/Quick/DBus) plus the Kirigami and
KirigamiAddons **runtime QML modules** and a QtQuick Controls style
(`qqc2-desktop-style`). In this dev container these are installed via
`.container/Dockerfile` — rebuild/restart the container first.

```sh
cmake -S . -B build -G Ninja
cmake --build build
```

Desktop integration (a `de.yoxcu.stoandl.gui.desktop` launcher entry + a hicolor icon
theme) lives in `data/` and installs to `<datadir>` via `cmake --build build --target
install`; the window icon is also embedded so it shows when run straight from `build/`.
See `data/README.md`.

## Run

The daemon is **not** D-Bus-activated; start it (or let the in-app button do it):

```sh
systemctl --user start stoandl     # optional — the GUI offers this too
./build/stoandl-gui
```

On a headless box, force the offscreen platform for a smoke test (no live UI):

```sh
QT_QPA_PLATFORM=offscreen ./build/stoandl-gui
```

## Testing without the real daemon (mock)

`tools/mock_stoandl.py` is a stateful stand-in for `de.yoxcu.stoandl.Control` that
implements the **full surface the GUI uses** — every screen's reads/mutations plus
the daemon-side hooks listed in the drift report. `tools/run-with-mock.sh` spins up
an ephemeral session bus, starts the mock on it, then launches the GUI:

```sh
tools/run-with-mock.sh                            # on a desktop
QT_QPA_PLATFORM=offscreen tools/run-with-mock.sh  # headless smoke test
tools/run-with-mock.sh --mock-only                # just the mock (Ctrl-C to stop)
```

Requires `dbus`, `python3-dbus`, `python3-gi` (installed via `.container/Dockerfile`).
For a Breeze-Dark look on a non-Plasma desktop, merge the `[Colors:*]` groups from
`docs/handoff/BreezeDark-dev-preview.kdeglobals` into `~/.config/kdeglobals`.

## Releases

CI is `.github/workflows/release.yml`: the Flatpak builds on every push/PR (the CI
gate — stock Ubuntu's Qt is too old to build natively), and pushing a `v*` tag
publishes a GitHub Release with a **`.flatpak` bundle**, a **source tarball**
(`stoandl-gui-<ver>.tar.gz`, for the postmarketOS/Alpine `packaging/APKBUILD`), and an
auto-generated changelog (`cliff.toml` — features / bug fixes, from Conventional
Commit messages). Built on the KDE runtime (`org.kde.Platform` — see
`data/de.yoxcu.stoandl.gui.flatpak.yml`); KirigamiAddons ships in that runtime, so it
isn't bundled.

### Installing / testing a Flatpak build

A `.flatpak` bundle isn't runnable directly — you `flatpak install` it first (a fast
import, not a rebuild):

```sh
# grab the bundle: a CI build artifact (any push) …
gh run download -R yoxcu/stoandl-gui -n flatpak-bundle
# … or a tagged release asset
gh release download -R yoxcu/stoandl-gui -p '*.flatpak'

flatpak remote-add --if-not-exists --user flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user de.yoxcu.stoandl.gui.flatpak     # pulls the org.kde.Platform runtime
flatpak run de.yoxcu.stoandl.gui
```

Start the daemon on the host first (`systemctl --user start stoandl`) — the sandboxed
GUI reaches it over the session bus. Sandbox limits: backup/restore/support (which
shell out to the `stoandl` CLI) and the in-app "start daemon" button don't work inside
the Flatpak; the D-Bus features do. **For day-to-day development, skip the Flatpak** and
just build + run natively (`cmake --build build && ./build/stoandl-gui`).
