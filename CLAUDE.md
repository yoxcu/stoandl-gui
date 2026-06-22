# stoandl-gui

Kirigami (Qt6/QML) front-end for the stoandl Pebble daemon. Convergent: Plasma Mobile + desktop.

## Architecture
- QML UI (Kirigami + KirigamiAddons FormCard) + one C++ shim `StoandlClient` (raw `QDBusConnection`).
- Talks to `de.yoxcu.stoandl.Control`, session bus, path `/de/yoxcu/stoandl`. Full contract:
  `docs/handoff/dbus-interface.md`. No code shared with the daemon — we are just another client.
- Builds musl-native (Alpine/postmarketOS) and glibc (desktop). No JVM.

## Navigation — 5 tabs (current)
**Watch · Health · Apps · Notifications · Settings** in `Kirigami.NavigationTabBar` (KDE HIG: ≤5
destinations → tab bar, not a drawer). **Watch is tab 0** (the launch view). Responsive: the tab bar is
in the window *footer*, so it sits BELOW content on mobile and relocates ABOVE on desktop. Extensions
are the 3rd segment of **Apps** (Faces / Apps / Extensions). Sync services live in **Settings**. The nav
is hidden when the daemon is down (nothing works without it).

## Hard rules
- **The interface has NO signals/properties.** Every live value is polled. All polling lives in
  `StoandlClient` (focus poll 4s for ListWatches; op pollers for Pair/Firmware/Language at the
  CLI cadences). UI never polls directly.
- **After any mutating call, re-fetch that screen's list.** There is no change event.
- Returns are either `kind:message` (split on first `:`) or tab-separated `as` records. Parse in
  `StoandlClient`, never in QML. Handle `notready` as the "no watch / not ready" empty state.
- The daemon is NOT D-Bus-activated. If the bus name is unowned → show "daemon not running", offer
  `systemctl --user start stoandl`. Never assume it's up.
- Paths passed to SideloadApp/SideloadFirmware/etc. are **absolute, daemon-side**.
- **Actions go on the page `actions`, never hand-placed header buttons.** Kirigami renders page actions
  in the header (desktop) and a bottom footer toolbar (mobile). There is **NO round floating FAB** — the
  prototype's round "+" is a Material idiom; the footer toolbar is the by-the-book KDE rendering.
- **Never hardcode colors or fonts.** Use `Kirigami.Theme` roles + `Kirigami.Units` spacing. The
  prototype's dark hexes are a density spec, not a color spec.
- Row actions are **inline** (trailing buttons in the delegate), **not kebabs**.

## Status kinds
ok · error · notready · notfound · ambiguous · pending · timeout · inprogress · reboot · failed ·
done · uptodate · disabled · busy · idle · none · confirm (PairStatus `confirm:<code>` — numeric
comparison awaiting ConfirmPairing(bool))

## Daemon hooks (added this milestone — see the drift report `docs/handoff/drift-report.md`)
The GUI now consumes daemon-side hooks beyond the original 51 methods: `transport` on ListWatches +
`synced` on ListApps (#4); `GetSyncStatus`/`SetSyncEnabled` (#5); `ExtList.config` + `ExtOpenConfig` +
`ExtConfigSchema`/`ExtGetConfig`/`ExtSetConfig` (#7); `GetHealthSummary`/`GetHealthSeries` (#8);
`SetWatchNickname` (#9); `GetConfigSchema`/`GetConfig`/`SetConfig` (#10); `WatchDetails`; notification
quiet-hours + filters; a changelog URL on `CheckFirmware`. All are implemented in the mock
(`tools/mock_stoandl.py`) and must be grown in the real Kotlin daemon to match.

## Not on D-Bus (shell out to the `stoandl` CLI, co-located): backup, restore, support bundle.

## Design reference
Target look/layout/states = the "KDE Kirigami by-the-book" prototype (`docs/stoandl KDE by-the-book.html`
→ `docs/kde-hig.jsx`). Match its FormCard grouping, page-action placement (header/footer toolbar, NOT a
FAB), passive-notification toasts, and danger-zone styling — in structure and density, taking colors
from the system theme.
