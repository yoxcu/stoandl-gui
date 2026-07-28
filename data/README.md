# Desktop integration assets

Launcher entry and application icons for the stoandl GUI. On the GTK4 branch cargo
only builds the binary, so these are installed by the packaging build — the APKBUILD
(`abuild`) and the Flatpak manifest (`data/de.yoxcu.stoandl.gui.flatpak.yml`) each copy
them into place, no manual copying needed:

| File                                         | Installed to                                          |
| -------------------------------------------- | ----------------------------------------------------- |
| `de.yoxcu.stoandl.gui.desktop`               | `<datadir>/applications/`                             |
| `de.yoxcu.stoandl.gui.metainfo.xml`          | `<datadir>/metainfo/`                                 |
| `icons/hicolor/**`                           | `<datadir>/icons/hicolor/**`                          |

> **Wayland note:** the window icon comes from the compositor matching the window's
> `app_id` (`de.yoxcu.stoandl.gui`) to the **installed** `.desktop` file and reading its
> `Icon=`. Running the binary straight from `gtk/target/` shows no icon on Wayland — the
> `.desktop` file and icon tree must be installed first (an `apk add` / Flatpak install
> does this, or `install -D` them into a prefix on `XDG_DATA_DIRS` by hand).

The application ID is **`de.yoxcu.stoandl.gui`** — the reverse-DNS of the app's domain
(`yoxcu.de`) and a sibling of the daemon's bus name `de.yoxcu.stoandl`. The desktop-file
basename, the Wayland `app_id` (the GApplication application id), and the `Icon=` key all
share this name so the launcher/taskbar resolves the icon via the installed `.desktop`
match. The GTK build does not embed the window icon in the binary, so it only shows once
the icon tree and `.desktop` file are installed.

## Icon design

A two-arrow **refresh / sync** mark — flat, free-form (no tile), Breeze-native, legible
down to ~24 px; the `-symbolic` variant covers smaller mono / tray contexts.

- Mark teal: `#0f9d94` (flat)
- Symbolic ink: `#232629`

`icons/hicolor/` is the single source of truth: scalable SVG + `-symbolic` SVG +
raster fallbacks (16 → 512 px).
