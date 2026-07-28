# stoandl-gui — GTK4 / libadwaita rewrite (branch `gtk-rewrite`)

A native **Rust + GTK4 + libadwaita** rewrite of the Kirigami/QML front-end for the
stoandl Pebble daemon, following the GNOME HIG. Wayland-only, no legacy X11 paths.
Same D-Bus contract, same app-id, roughly the same feature set and structure.

> **Spec sources.** The authoritative behavioural spec for every screen is
> [`existing-app-map.json`](./existing-app-map.json) (a full map of the Qt app —
> features, D-Bus calls, states, gotchas, and per-widget GNOME mapping notes).
> The D-Bus contract itself is [`../dbus-interface.md`](../dbus-interface.md) and
> [`../drift-report.md`](../drift-report.md). This file is the *how we build it in
> GTK* layer on top of those. The Qt sources under `qml/` + `src/` stay in the
> branch as the porting reference until parity is reached (then a cleanup commit
> removes them).

## Decisions

| Area | Choice | Why |
|------|--------|-----|
| Language | Rust 2021 | Native, no runtime; first-class musl static + glibc; matches "no JVM" constraint. |
| Toolkit | GTK 4 + libadwaita ≥ 1.5 | GNOME HIG platform. |
| Bindings | `gtk4` (`gtk`) + `libadwaita` (`adw`) crates | Mature gtk-rs. |
| D-Bus | **GLib GDBus via the `gio` crate** (NOT zbus) | Already lives on the GTK main loop — `DBusConnection::call_future` + `spawn_future_local`, no second async runtime, no libdbus. This is the one deviation from the "zbus" note in the kickoff question; GDBus is the correct fit for a GTK app and is what the map's GNOME-mapping notes recommend. |
| UI authoring | **Blueprint** (`.blp`) → `.ui` → GResource, loaded as composite templates | Modern, maintainable GNOME idiom; declarative UI out of Rust. Compiled in `build.rs`. |
| Build | **Cargo** (dev) + `build.rs` for resources | Self-contained; a Meson wrapper for packaging can be added later. |
| App-id | `de.yoxcu.stoandl.gui` (unchanged) | Wayland app_id, GApplication id, GResource prefix `/de/yoxcu/stoandl/gui`, .desktop/metainfo/icon name. |
| Layout | new crate under `gtk/`, reuse `data/` (desktop/metainfo/icons) | Keeps the Qt tree untouched during the port. |

## Async / threading model

Single-threaded GTK main loop. Every D-Bus call is `async` on the GLib
`MainContext`:

- `gio::bus_get_future(BusType::Session)` once at startup → one `DBusConnection`.
- Calls: `conn.call_future(Some(NAME), PATH, IFACE, method, params, reply_type, flags, timeout_ms)` returning `glib::Variant`. 10 s default timeout; 20 s for `FindWatch`.
- UI handlers launch calls with `glib::spawn_future_local(clone!(...))`; on completion they update widgets directly (same thread, no channels needed).
- Daemon liveness: `gio::bus_watch_name` (name-appeared / name-vanished) drives the `daemon-up` property — cleaner than polling `NameHasOwner`, but still do one `NameHasOwner`-equivalent implicitly via the initial watch callback.
- Signals: `conn.signal_subscribe(Some(NAME), Some(IFACE), Some(signal), Some(PATH), None, flags, cb)` — one per the 7 Control signals.
- Timers (safety-net polls / op watchdogs): `glib::timeout_add_seconds_local` / `timeout_add_local`, storing the `SourceId` to remove on stop.
- CLI shell-outs (backup/restore/support) and `systemctl --user start stoandl`: `gio::Subprocess` with `communicate_utf8_future`.
- `Gtk.UriLauncher` for opening config/changelog URLs; `Gtk.FileDialog` for pickers.

The daemon is **not** D-Bus-activated, so polling + re-sync-on-daemon-up stays as
the fallback beneath the 7 signals — see the "Hard rules" in `../../CLAUDE.md`.

## The D-Bus client (`src/dbus/`)

`StoandlClient` — a `GObject` singleton, the sole thing that touches D-Bus
(analogue of the Qt `StoandlClient` shim). It:

- Owns the `DBusConnection`, exposes `daemon-up` + `bluetooth-on` GObject
  **properties** (widgets bind reactively) and **signals** for each reactive
  push: `watches-changed`, `apps-changed`, `extensions-changed`,
  `calendars-changed`, `pair-status(kind, msg)`, `firmware-status(kind, pct, detail)`,
  `language-status(kind, pct, detail)`, `find-watch-result(bool)`, `cli-result(op, ok, msg)`.
- Subscribes to the 7 Control signals and maps each to its refresh path exactly as
  the Qt shim does (see map slice "StoandlClient"): `WatchesChanged`→re-fetch
  watches; `FirmwareProgress`→normalised firmware-status; `LockerChanged`→apps;
  `LanguageProgress`→language-status; `ExtensionsChanged`→extensions;
  `ExtensionStateChanged(name,state)`→record in a `name→state` map, merge into
  ExtList rows, re-fetch; `CalendarsChanged`→calendars.
- Keeps the safety-net pollers: 20 s watch poll (carries `BluetoothStatus`), 1.5 s
  pair poll (145 s ceiling), 0.8 s firmware poll (600 s ceiling), 3 s language
  watchdog (180 s ceiling).
- **Parsing lives here, never in the UI** (`src/dbus/parse.rs`, pure functions,
  fully unit-testable):
  - `parse_status(&str) -> Status { kind, tail, fields: Vec<String> }` — split on the
    **first** `:` only; `tail` split on **TAB** into `fields`. `ok = kind=="ok"`,
    `notready = kind=="notready"`.
  - `parse_records(Vec<String>) -> Vec<Vec<String>>` — each `as` element split on TAB.
  - Field-typed row builders per method (watch/app/pref/calendar/etc.), returning
    typed Rust structs backing `gio::ListStore` (or plain `Vec` for simple lists).
  - **Gotchas to preserve** (all in the map): `allowed` in `ListWatchPrefs` is
    **pipe(`|`)-separated** for enum/quicklaunch/color/number-range (everything else
    is comma); number `current` like `"3000 ms"` → take leading digits; enum
    options are display names; quicklaunch is an **app picker** (`Off` + app titles),
    never a slider/uuid; calendar password is write-only; firmware success =
    `reboot` **or** a `notready` seen *after* activity; extension run-state override;
    `NotifSetMuteAll` has no getter (derive "all muted" from per-app list).

Return types on the wire are only `s`, `b`, `as`, void → trivial `glib::Variant`
(un)packing.

## UI structure (Kirigami → Adwaita)

Top-level: `Adw.ApplicationWindow` → `Adw.ToastOverlay` (app-wide; every page
posts `Adw.Toast` via `window.toast()`) → `Gtk.Stack root_stack` with two children:

- **`daemon`**: `Adw.StatusPage` ("daemon not running", `systemctl --user start
  stoandl` button) shown when `daemon-up` is false — the whole nav disappears.
- **`main`**: `Adw.ToolbarView` with `Adw.HeaderBar` (top) carrying an
  `Adw.ViewSwitcher` (title widget, wide policy) + an `Adw.ViewSwitcherBar`
  (bottom bar, revealed on narrow) both driving an `Adw.ViewStack view_stack` with
  the 5 destinations. This reproduces the convergent "tab bar below on mobile / top
  on desktop" behaviour natively via an `Adw.Breakpoint` (≤ ~550sp → reveal the
  bottom switcher bar, swap the header title-widget to a plain label). Drop the
  Kirigami `isMobile` concept entirely — layout is size-driven.

Each of the 5 destinations is an `Adw.ViewStackPage` whose child is an
`Adw.NavigationView` (so Settings sub-pages, the Watch details view and the
Notifications per-app view are real `Adw.NavigationPage` pushes with a back
button; switching tabs / re-tapping is not needed to pop, GTK gives the back
button — but the app still pops sub-pages to root on tab switch for parity).

Per-page shell: `Adw.NavigationPage` → `Adw.ToolbarView` (`Adw.HeaderBar` for
title + page actions) → `Gtk.ScrolledWindow` → `Adw.PreferencesPage` /
`Adw.Clamp`+`Gtk.Box`. Pinned segment/period switchers go in the header (or a
second `Adw.ToolbarView` top bar), never in the scrolling content. **No FAB** —
page actions are `Gtk.Button`s in the `Adw.HeaderBar` (GNOME convention agrees
with the KDE rule).

### Widget mapping (used consistently everywhere)

| Kirigami / QML | GTK4 / libadwaita |
|---|---|
| `ApplicationWindow` + `showPassiveNotification` | `Adw.ApplicationWindow` + `Adw.ToastOverlay`/`Adw.Toast` |
| `NavigationTabBar` (footer, responsive) | `Adw.ViewStack` + `Adw.ViewSwitcher` (header) + `Adw.ViewSwitcherBar` (bottom, via `Adw.Breakpoint`) |
| `pageStack.push`/`pop` sub-pages | `Adw.NavigationView` + `Adw.NavigationPage` |
| `ScrollablePage` | `Adw.NavigationPage` → `Adw.ToolbarView` → `ScrolledWindow` → `Adw.PreferencesPage` |
| `FormCard.FormHeader` + `FormCard` | `Adw.PreferencesGroup` (title/description) |
| `FormButtonDelegate` | `Adw.ActionRow`/`Adw.ButtonRow` (activatable, go-next) |
| `FormSwitchDelegate` | `Adw.SwitchRow` |
| `FormComboBoxDelegate` | `Adw.ComboRow` (`Gtk.StringList`) |
| `FormSpinBoxDelegate` | `Adw.SpinRow` (`Gtk.Adjustment`; unit via `output`/format; **debounce** the write with a `timeout`) |
| `FormTextFieldDelegate` | `Adw.EntryRow` / `Adw.PasswordEntryRow` (secret) |
| calendar account (nested toggles) | `Adw.ExpanderRow` (suffix edit/remove buttons) → child `Adw.SwitchRow`s |
| `AbstractFormDelegate` hero / app / watch row | activatable `Adw.ActionRow` (leading `Gtk.Image`, suffix widgets) |
| `StatusChip` (tinted pill) | `Gtk.Label` with a `pill` CSS class + `.success`/`.warning`/`.error`/`.dim-label` |
| `InlineMessage` / update banner | `Adw.Banner` |
| `PlaceholderMessage` / daemon-down / notready / BT-off / no-HR | `Adw.StatusPage` (icon + title + description + action button) |
| `PromptDialog` (confirm/pair/forget/factory) | `Adw.AlertDialog` (responses; `.destructive-action`; type-to-confirm via an `Adw.EntryRow` gating a response) |
| `Kirigami.Dialog` (watch details, ext schema, per-app notif) | `Adw.Dialog`/`Adw.PreferencesDialog` (auto bottom-sheet on narrow) or an `Adw.NavigationView` inside a dialog for the multi-view details |
| health charts (bars / sleep timeline / HR line + area) | `Gtk.DrawingArea` with a Cairo `draw_func`, colours from theme (`@accent_color`, `@error_color`, `widget.color()`) — never hardcoded |
| firmware/language progress | `Gtk.ProgressBar` (in the banner / a row); `pulse()` when percent < 0 |
| `Qt.openUrlExternally` | `Gtk.UriLauncher` |
| `FileDialog` | `Gtk.FileDialog` + `Gtk.FileFilter` |
| row inline actions (hover/swipe) | always-visible flat `Gtk.Button` suffixes (GTK has no swipe-to-reveal) |
| Kirigami.Theme roles / Units | libadwaita named colours + CSS style classes; 6/12px spacing; `Adw.StyleManager` for light/dark/accent |

## Module layout (`gtk/`)

```
gtk/
  Cargo.toml            gtk4 + libadwaita deps; glib-build-tools build-dep
  build.rs              .blp → .ui (blueprint-compiler) → GResource
  resources/
    resources.gresource.xml
    style.css           pill/mono/chart helper classes only
  ui/
    window.blp          the shell (root_stack + view_stack + switchers + breakpoint)
    <page>.blp ...      per page (added during implementation)
  src/
    main.rs             register resources, run StoandlApplication
    config.rs           APP_ID, RESOURCE_PREFIX, DBUS_NAME/PATH/IFACE
    application.rs       Adw.Application subclass
    window.rs           Adw.ApplicationWindow composite template + client wiring + toast()
    dbus/
      mod.rs
      client.rs         StoandlClient GObject: connection, props, signals, calls, pollers
      parse.rs          parse_status / parse_records + typed row builders (+ unit tests)
    pages/
      mod.rs
      watch.rs, health.rs, apps.rs, notifications.rs,
      settings.rs, sync.rs, calendars.rs, watch_prefs.rs, general.rs, backup.rs
    widgets/
      status_chip.rs, chart.rs, ...   (custom widgets as needed)
```

## Build & test

- **Build (out-of-tree, persistent):** `CARGO_TARGET_DIR` is set in the Dockerfile
  to `/home/vscode/.cache/stoandl/gtk-target` so artifacts persist across restarts
  and never touch the bind-mounted `/workspace`. Just `cargo build` from `gtk/`.
- **Resources:** `build.rs` runs `blueprint-compiler batch-compile` on every
  `ui/*.blp`, copies `style.css`, then `glib_build_tools::compile_resources` bundles
  them; `main.rs` does `gio::resources_register_include!("stoandl.gresource")`.
- **Mock daemon:** `tools/mock_stoandl.py` is toolkit-agnostic and reused verbatim
  (it already serves the full contract + 7 signals; add `CalendarsChanged` if the
  signal block is missing it). `tools/run-with-mock-gtk.sh` launches the GTK binary
  on an ephemeral `dbus-run-session` bus with the mock (mirrors `run-with-mock.sh`).
- **Headless smoke test:** GTK has no offscreen platform like Qt's. Use a headless
  Wayland compositor: `weston --backend=headless-backend.so` (installed) provides a
  `WAYLAND_DISPLAY`; run the app under it + the mock, drive `view_stack` across all
  5 pages via a temporary debug timer, and grep stderr for `Gtk`/`Adwaita`/`CRITICAL`/
  `WARNING` (analogue of the Qt offscreen tab-cycle test in memory
  `headless-gui-verification`). Screenshots need `weston-screenshooter` or a
  `GskRenderer` render-to-`.png` debug hook.
- **Packaging validators:** `desktop-file-validate` + `xmllint`/`appstreamcli` on
  `data/*` (unchanged; app-id identical).

## Porting order (parity target)

1. Scaffold: window shell + `StoandlClient` (connection, `daemon-up`, one call) — proves toolchain.
2. `StoandlClient` full: all methods, 7 signals, pollers, `parse.rs` + tests.
3. Watch (+ details view, pairing, firmware, language) — the launch tab.
4. Health (period model + charts).
5. Apps (Faces/Apps/Extensions + schema config dialog).
6. Notifications (master/mute/per-app view/filters).
7. Settings landing → Sync / Calendars / Watch prefs / General / Backup.
8. Empty/error/notready/BT-off states, toasts, danger-zone styling everywhere.
9. Headless verification pass; packaging; cleanup commit removing the Qt tree.
