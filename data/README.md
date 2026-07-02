# Desktop integration assets

Launcher entry and application icons for the stoandl GUI. These are installed by
CMake (`cmake --build build --target install`) — no manual copying needed:

| File                                         | Installed to                                          |
| -------------------------------------------- | ----------------------------------------------------- |
| `de.yoxcu.stoandl.gui.desktop`               | `<datadir>/applications/`                             |
| `de.yoxcu.stoandl.gui.metainfo.xml`          | `<datadir>/metainfo/`                                 |
| `icons/hicolor/**`                           | `<datadir>/icons/hicolor/**`                          |

> **Wayland note:** the window icon comes from the compositor matching the window's
> `app_id` (`de.yoxcu.stoandl.gui`) to the **installed** `.desktop` file and reading its
> `Icon=`. Running the binary straight from `build/` shows no icon on Wayland — you must
> install (`cmake --install build --prefix ~/.local`). The embedded Qt-resource icon only
> covers X11 / the uninstalled case.

The application ID is **`de.yoxcu.stoandl.gui`** — the reverse-DNS of the app's
`setOrganizationDomain` (`yoxcu.de`) and a sibling of the daemon's bus name
`de.yoxcu.stoandl`. The desktop-file basename, the Wayland `app_id`
(`setDesktopFileName` in `src/main.cpp`), and the `Icon=` key all share this name so
the launcher/taskbar resolves the icon on both Wayland (via the `.desktop` match) and
X11 (via `QApplication::setWindowIcon`). A subset of the PNG sizes is also embedded as
a Qt resource so the window icon shows even when running uninstalled from `build/`.

## Icon design

A two-arrow **refresh / sync** mark — flat, free-form (no tile), Breeze-native, legible
down to ~24 px; the `-symbolic` variant covers smaller mono / tray contexts.

- Mark teal: `#0f9d94` (flat)
- Symbolic ink: `#232629`

`icons/hicolor/` is the single source of truth: scalable SVG + `-symbolic` SVG +
raster fallbacks (16 → 512 px).
