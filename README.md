# stoandl-gui

Kirigami (Qt6 / QML) front-end for the **stoandl** Pebble companion daemon.
Convergent: Plasma Mobile + desktop. See `CLAUDE.md` and `docs/handoff/` for the
full spec, the D-Bus contract, and the visual prototype.

## Status

`StoandlClient` (C++ QML singleton) is the only thing that touches D-Bus: generic
`call`/`list`, typed wrappers (one per method, parsing every tab-record and status
string), `daemonUp` via `NameHasOwner` (+ reactive `NameOwnerChanged`), and all
polling. Shared QML: `StatusChip`, `DaemonPlaceholder`. `Kirigami.ApplicationWindow`
+ a `Kirigami.NavigationTabBar` footer (responsive: bottom on mobile, top on
desktop) with five destinations — **Watch · Health · Apps · Notifications ·
Settings** — and **Watch is tab 0**. The nav hides when the daemon is down.

- **Watch** — firmware-update `InlineMessage` banner (Update now flashes inline via
  the `FirmwareStatus` poll; What's new opens the PebbleOS changelog), a tappable
  active-watch hero card → **Watch details dialog** (Model/Platform/Transport/
  Firmware+What's-new/Serial/Battery/Last-sync, a Developer-connection toggle, a
  Language picker, a Rename pencil, a **Debug** submenu — core dump · pull logs ·
  support bundle · reboot-to-recovery · write-notification [SOON] · factory reset —
  and Forget watch), and a known-watches list with inline Connect/active + forget
  (no kebab). Pair / Ring / Sync-now as page actions. 4 s `ListWatches` focus poll;
  1.5 s / 145 s `PairStatus` poll.
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
- **Notifications** — Forward-notifications master toggle + Mute-temporarily;
  per-app list → a deeper per-app dialog (mute, vibration pattern, custom icon,
  allow-during-quiet); scheduled Quiet hours + Quiet-now; regex Filters (allow/block,
  Add-filter page action). Maps to `NotifList`/`NotifSetMute`/`NotifSetMuteAll`/
  `NotifSetStyle` + the quiet-hours/filter hooks.
- **Settings** — Sync services (per-service master toggles via `GetSyncStatus`/
  `SetSyncEnabled` + force-sync + per-calendar toggles), Watch settings (from
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
