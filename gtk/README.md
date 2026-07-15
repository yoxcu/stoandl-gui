# stoandl-gui (GTK4 / libadwaita)

Native Rust rewrite of the stoandl Pebble front-end, following the GNOME HIG.
Wayland-only. Speaks the same `de.yoxcu.stoandl.Control` D-Bus contract as the
Kirigami build (which lives alongside in `../qml` + `../src` during the port).

See [`../docs/handoff/gtk-rewrite/ARCHITECTURE.md`](../docs/handoff/gtk-rewrite/ARCHITECTURE.md)
for the design and the Kirigami→Adwaita mapping, and
[`../docs/handoff/gtk-rewrite/existing-app-map.json`](../docs/handoff/gtk-rewrite/existing-app-map.json)
for the per-screen behavioural spec.

## Build & run

```sh
cd gtk
cargo build                      # build.rs compiles ui/*.blp → GResource
../tools/run-with-mock-gtk.sh    # run against the mock daemon (needs Wayland)
../tools/run-with-mock-gtk.sh --headless   # smoke test under a headless weston
cargo test                       # parse.rs unit tests
```

Requires the toolchain from `../.container/Dockerfile` (Rust, `libgtk-4-dev`,
`libadwaita-1-dev`, `blueprint-compiler`, `weston`). Build artifacts go to
`$CARGO_TARGET_DIR` (set to the persistent cache), never into the repo.

## Layout

- `ui/*.blp` — Blueprint UI, compiled to `.ui` and bundled as a GResource.
- `src/dbus/` — `StoandlClient` (the only D-Bus toucher) + wire parsing.
- `src/pages/` — one module per screen (Watch/Health/Apps/Notifications/Settings…).
- `src/window.rs` / `application.rs` — the Adwaita shell.
