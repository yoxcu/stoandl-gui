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
- **The interface has SIX signals (`WatchesChanged`/`FirmwareProgress`/`LockerChanged`/
  `LanguageProgress`/`ExtensionsChanged`/`ExtensionStateChanged`) that augment polling — polling
  stays as the fallback.**
  The daemon is NOT D-Bus-activated, so a late or reconnecting client can miss a signal; therefore
  the GUI keeps a slow safety-net poll **and** re-syncs on `daemonUpChanged`. All of this lives in
  `StoandlClient`: the signals re-use the existing `refreshWatches()`/`refreshApps()`/
  `refreshExtensions()`/`firmwareStatus(...)`/`languageStatus(...)` paths (QML unchanged); a 20s
  watch poll carries `BluetoothStatus` + is the missed-`WatchesChanged` net; op pollers for
  Pair/Firmware/Language stay (the firmware/language op-poll is the reboot/disconnect watchdog —
  the `FirmwareProgress`/`LanguageProgress` signal just smooths its % between ticks, so the
  language op-poll is relaxed to a 3s watchdog cadence). `ExtensionStateChanged(s name, s state)`
  is the finer companion to the `ExtensionsChanged` poke: it carries an unsolicited per-extension
  run-state transition (`ready`/`exited`/`quarantined`) the list-level poke can't — `StoandlClient`
  records it in a name→state map and merges it into the `ExtList` rows (so a quarantined/exited ext
  isn't shown as a stale "running"). UI never polls directly.
- **After any mutating call, still re-fetch that screen's list.** The signal is a best-effort poke,
  not a guarantee — the re-fetch is authoritative.
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
Six reactive **signals** — `WatchesChanged()` (re-call ListWatches), `FirmwareProgress(s phase,
i percent, s detail)` (push flash progress, same phase vocabulary as `FirmwareStatus`),
`LockerChanged()` (re-call ListApps), `LanguageProgress(s phase, i percent, s detail)` (push
language-install progress, same phase vocabulary as `LanguageStatus`), `ExtensionsChanged()`
(re-call ExtList), and `ExtensionStateChanged(s name, s state)` (the finer companion to
`ExtensionsChanged`: an unsolicited per-extension run-state transition — `state` ∈
`ready`/`exited`/`quarantined` — that the list-level poke can't catch, so a crashed/quarantined
extension shows live instead of a stale "running") — consumed on top of polling (see Hard rules).
The GUI also consumes daemon-side hooks beyond the original 51 methods: `transport` on ListWatches +
`synced` on ListApps (#4); `GetSyncStatus`/`SetSyncEnabled` (#5); `ExtList.config` + `ExtOpenConfig` +
`ExtConfigSchema`/`ExtGetConfig`/`ExtSetConfig` (#7); `GetHealthSummary`/`GetHealthSeries` (#8);
`SetWatchNickname` (#9); `GetConfigSchema`/`GetConfig`/`SetConfig` (#10); `WatchDetails`; notification
regex filters; a changelog URL on `CheckFirmware`. All are implemented in the mock
(`tools/mock_stoandl.py`) and must be grown in the real Kotlin daemon to match. (Notification
quiet-hours hooks were dropped — superseded by the daemon's `dnd.sync`.)

## Not on D-Bus (shell out to the `stoandl` CLI, co-located): backup, restore, support bundle.

## Design reference
Target look/layout/states = the "KDE Kirigami by-the-book" prototype (`docs/stoandl KDE by-the-book.html`
→ `docs/kde-hig.jsx`). Match its FormCard grouping, page-action placement (header/footer toolbar, NOT a
FAB), passive-notification toasts, and danger-zone styling — in structure and density, taking colors
from the system theme.
