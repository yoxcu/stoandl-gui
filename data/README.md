# Desktop integration assets (shared by both front-ends)

Launcher entries, AppStream metainfo and application icons. This tree is **shared**:
each of the two front-ends has its own `.desktop` / metainfo and its own app-icon
files, distinguished by app id, all living here:

| Variant  | Desktop / metainfo                          | App-icon files                     | Installed by |
| -------- | ------------------------------------------- | ---------------------------------- | ------------ |
| Kirigami | `de.yoxcu.stoandl.gui.{desktop,metainfo.xml}`     | `icons/hicolor/**/de.yoxcu.stoandl.gui.*`     | CMake (`kirigami/CMakeLists.txt`) |
| GTK      | `de.yoxcu.stoandl.gui.gtk.{desktop,metainfo.xml}` | `icons/hicolor/**/de.yoxcu.stoandl.gui.gtk.*` | cargo/flatpak/apk (`packaging/gtk/`, GTK flatpak manifest) |

They install to `<datadir>/applications`, `<datadir>/metainfo` and
`<datadir>/icons/hicolor/**`. Each variant ships **only its own** app-icon set — the
two are kept disjoint so both packages can be installed at once (native apk forbids two
packages owning the same path; and it stops flatpak's `${app-id}*` icon export from
cross-picking, since `de.yoxcu.stoandl.gui` is a prefix of `de.yoxcu.stoandl.gui.gtk`).
The heart action icon (`icons/hicolor/scalable/actions/stoandl-heart-symbolic.svg`) is
shipped by Kirigami only; the GTK build carries it inside its GResource bundle.

> **Wayland note:** the window icon comes from the compositor matching the window's
> `app_id` to the **installed** `.desktop` file and reading its `Icon=`. Running a
> binary straight from `build/` (Kirigami) / `target/` (GTK) shows no icon on Wayland —
> you must install it. Kirigami additionally embeds the icon as a Qt resource and GTK
> bundles it in its GResource, covering X11 / the uninstalled case.

Each application ID is the reverse-DNS of the app's domain (`yoxcu.de`) and a sibling
of the daemon's bus name `de.yoxcu.stoandl`: **`de.yoxcu.stoandl.gui`** (Kirigami,
`setDesktopFileName` in `kirigami/src/main.cpp`) and **`de.yoxcu.stoandl.gui.gtk`** (GTK,
`APP_ID` in `gtk/src/config.rs`). The desktop-file basename, the Wayland `app_id` and
the `Icon=` key all share the variant's id so the launcher/taskbar resolves the icon.

## Icon design

A two-arrow **refresh / sync** mark — flat, free-form (no tile), Breeze-native, legible
down to ~24 px; the `-symbolic` variant covers smaller mono / tray contexts.

- Mark teal: `#0f9d94` (flat)
- Symbolic ink: `#232629`

`icons/hicolor/` is the single source of truth: scalable SVG + `-symbolic` SVG +
raster fallbacks (16 → 512 px).
