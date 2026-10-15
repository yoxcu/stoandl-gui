# Desktop integration assets

Launcher entry, AppStream metainfo and application icons for the Kirigami GUI:

| Desktop / metainfo                            | App-icon files                            | Installed by |
| --------------------------------------------- | ----------------------------------------- | ------------ |
| `de.yoxcu.stoandl.gui.{desktop,metainfo.xml}` | `icons/hicolor/**/de.yoxcu.stoandl.gui.*` | CMake (`kirigami/CMakeLists.txt`) |

They install to `<datadir>/applications`, `<datadir>/metainfo` and
`<datadir>/icons/hicolor/**`, together with the heart action icon
(`icons/hicolor/scalable/actions/stoandl-heart-symbolic.svg`).

> **Wayland note:** the window icon comes from the compositor matching the window's
> `app_id` to the **installed** `.desktop` file and reading its `Icon=`. Running the
> binary straight from `build/` shows no icon on Wayland — you must install it. The app
> additionally embeds the icon as a Qt resource, covering X11 / the uninstalled case.

The application ID is the reverse-DNS of the app's domain (`yoxcu.de`) and a sibling
of the daemon's bus name `de.yoxcu.stoandl`: **`de.yoxcu.stoandl.gui`**
(`setDesktopFileName` in `kirigami/src/main.cpp`). The desktop-file basename, the
Wayland `app_id` and the `Icon=` key all share that id so the launcher/taskbar resolves
the icon.

## Icon design

A two-arrow **refresh / sync** mark — flat, free-form (no tile), Breeze-native, legible
down to ~24 px; the `-symbolic` variant covers smaller mono / tray contexts.

- Mark teal: `#0f9d94` (flat)
- Symbolic ink: `#232629`

`icons/hicolor/` is the single source of truth: scalable SVG + `-symbolic` SVG +
raster fallbacks (16 → 512 px).
