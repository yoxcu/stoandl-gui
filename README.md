<p align="center"><img src="data/icons/hicolor/256x256/apps/de.yoxcu.stoandl.gui.png" alt="stoandl-gui" width="120"></p>

# stoandl-gui

Kirigami (Qt6 / QML) front-end for the **stoandl** Pebble companion daemon.
Convergent: Plasma Mobile + desktop.

## Screenshots

<table>
  <tr>
    <td align="center" width="33%"><img src="docs/screenshots/watch.png" width="230" alt="Watch tab"><br><sub><b>Watch</b> — pairing, firmware, battery</sub></td>
    <td align="center" width="33%"><img src="docs/screenshots/health.png" width="230" alt="Health tab"><br><sub><b>Health</b> — steps, sleep, heart rate</sub></td>
    <td align="center" width="33%"><img src="docs/screenshots/apps.png" width="230" alt="Apps tab"><br><sub><b>Apps</b> — faces, apps, extensions</sub></td>
  </tr>
  <tr>
    <td align="center" width="33%"><img src="docs/screenshots/alerts.png" width="230" alt="Alerts tab"><br><sub><b>Alerts</b> — per-app mute, filters</sub></td>
    <td align="center" width="33%"><img src="docs/screenshots/settings.png" width="230" alt="Settings"><br><sub><b>Settings</b> — sync, calendars, config</sub></td>
    <td align="center" width="33%"><img src="docs/screenshots/battery.png" width="230" alt="Battery insights"><br><sub><b>Battery insights</b> — charge, drain, power</sub></td>
  </tr>
</table>

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
the extra daemon-side hooks the GUI relies on. `tools/run-with-mock.sh` spins up
an ephemeral session bus, starts the mock on it, then launches the GUI:

```sh
tools/run-with-mock.sh                            # on a desktop
QT_QPA_PLATFORM=offscreen tools/run-with-mock.sh  # headless smoke test
tools/run-with-mock.sh --mock-only                # just the mock (Ctrl-C to stop)
```

Requires `dbus`, `python3-dbus`, `python3-gi` (installed via `.container/Dockerfile`).

## Releases

CI is `.github/workflows/release.yml`: the Flatpak builds on every push/PR (the CI
gate — stock Ubuntu's Qt is too old to build natively), and pushing a `v*` tag
publishes a GitHub Release with a **`.flatpak` bundle**, a **source tarball**
(`stoandl-gui-<ver>.tar.gz`, for the postmarketOS/Alpine `packaging/APKBUILD`), and an
auto-generated changelog (`cliff.toml` — features / bug fixes, from Conventional
Commit messages). Built on the KDE runtime (`org.kde.Platform` — see
`data/de.yoxcu.stoandl.gui.flatpak.yml`); KirigamiAddons ships in that runtime, so it
isn't bundled.

**Installing the postmarketOS `.apk`.** A tagged release also ships an aarch64 pmOS `.apk`
and the public signing key (`mick@yoxcu.de-*.rsa.pub`). Trust the key once and `apk add`
installs it — and every future release — without `--allow-untrusted`:

```sh
# from the release page, download the .apk and the matching .rsa.pub, then:
doas cp mick@yoxcu.de-*.rsa.pub /etc/apk/keys/   # trust the signing key (once)
doas apk add ./stoandl-gui-*.apk
```

(Or skip the key with `doas apk add --allow-untrusted ./stoandl-gui-*.apk`.)

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
