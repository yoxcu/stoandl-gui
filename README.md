# stoandl-gui

**GTK4 / libadwaita** front-end for the **stoandl** Pebble companion daemon.
Convergent: GNOME desktop + Linux phones (phosh / postmarketOS).

> This is the **`gtk-rewrite`** branch — the native GTK4 app (Rust, in [`gtk/`](gtk/)).
> The original **Kirigami (Qt6/QML)** app lives on **`main`**. The two front-ends
> coexist on separate branches; both are independent clients of the same
> `de.yoxcu.stoandl.Control` D-Bus interface.

The app is a single Rust crate under [`gtk/`](gtk/) — gtk4-rs + libadwaita +
Blueprint UI, D-Bus via GLib GDBus (no second runtime). See
[`gtk/README.md`](gtk/README.md) for the crate layout and
[`docs/handoff/dbus-interface.md`](docs/handoff/dbus-interface.md) for the D-Bus
contract.

## Screens

Five tabs in an `Adw.ViewStack` (responsive: header switcher on desktop, bottom
switcher bar on narrow) — **Watch · Health · Apps · Alerts · Settings**; Watch is
tab 0. The whole nav hides when the daemon is down.

- **Watch** — firmware update/flash banner, active-watch hero → details / debug /
  language / **battery-insights** sub-pages, and a known-watches list with inline
  connect / forget (surfaces the `connecting` state).
- **Health** — period-based (Daily / Weekly / Monthly) steps / sleep / heart-rate
  cards + per-day bar charts, Cairo-drawn and theme-coloured.
- **Apps & Faces** — Faces / Apps / Extensions segments; launch, reorder
  (+ restore default order), config, install / uninstall.
- **Alerts** — forward-notifications master + per-app mute / vibration / icon /
  colour + regex filters.
- **Settings** — Sync (with live now-playing on the Music row), Calendars, Watch
  prefs, **Health profile**, Daemon config, Backup.

## Build

Rust + gtk4-rs; needs `libgtk-4-dev`, `libadwaita-1-dev`, `blueprint-compiler`,
and `glib-compile-resources` at build time.

```sh
cd gtk
cargo build --release
cargo run            # against the real daemon on a GNOME session
```

## Testing without the real daemon (mock)

`tools/mock_stoandl.py` is a stateful stand-in for `de.yoxcu.stoandl.Control`
implementing the full surface the GUI uses. `tools/run-with-mock-gtk.sh` spins an
ephemeral session bus, starts the mock, and runs the app:

```sh
tools/run-with-mock-gtk.sh              # on a Wayland session
tools/run-with-mock-gtk.sh --headless   # offscreen smoke test (headless weston)
tools/run-with-mock-gtk.sh --mock-only  # just the mock (Ctrl-C to stop)
```

## Packaging

A Flatpak manifest (`data/de.yoxcu.stoandl.gui.flatpak.yml`) and an Alpine /
postmarketOS `APKBUILD` (`packaging/`) build the Rust app. A GitHub Actions
pipeline (`.github/workflows/release.yml`) publishes a Flatpak bundle, a source
tarball + git-cliff changelog, and a signed aarch64 pmOS `.apk` on tagged
releases.
