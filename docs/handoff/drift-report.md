# Drift report — GUI rebuild to the new 5-tab spec

Scope: the full GUI restructure (nav → **Watch · Health · Apps · Notifications · Settings**, Extensions
folded into Apps, Sync into Settings, new Health + Notifications screens, Watch-details dialog) plus the
daemon-side hooks needed to make it work. The hooks are implemented in the mock (`tools/mock_stoandl.py`)
and consumed by the GUI; the real Kotlin daemon must grow the same surface. Format follows handoff §8.

---

## 1 · D-Bus contract deltas (vs `docs/handoff/dbus-interface.md`)

### Changed records (existing methods, extra fields)

| Method | Doc record | New record | Hook |
|---|---|---|---|
| `ListWatches` | `name\tstate\tbattery` | `name\tstate\tbattery\t**transport**` (transport ∈ `ble`\|`classic`, empty when disconnected) | #4 |
| `ListApps` | flags ⊆ `{active,sideloaded,config,system}` | flags gains **`synced`** → `{…,synced}` | #4 |
| `ExtList` | `name\tinstalled\tenabled\trunning` | `name\tinstalled\tenabled\trunning\t**config**\t**description**` (config ∈ `none`\|`url`\|`schema`) | #7 |
| `CheckFirmware` | `ok:board\tcurrent\tlatest\tasset\tyes\|no\tsource` | …`\t**changelogUrl**` (7th field) | new — the Watch banner's "What's new" link needs it; nothing in the 51 carries a changelog URL |

### New methods (the hooks)

| Method | Sig | Returns | Hook |
|---|---|---|---|
| `WatchDetails` | `() → s` | `ok:name\tcode\tmodel\tplatform\ttransport\tfirmware\tserial\tbattery\tlastSync` / `notready:` (Board omitted per §4d) | identity gap (Screen 1) — wiring-only |
| `SetWatchNickname` | `(s,s) → s` | rename a known watch | #9 |
| `GetSyncStatus` | `() → as` | `service\tenabled\tavailable\tlastSync` for `{notifications,weather,calendar,music,health,dnd}` | #5 |
| `SetSyncEnabled` | `(s,b) → s` | runtime master on/off | #5 |
| `ExtOpenConfig` | `(s) → s` | `ok:<http-url>` (url backend) / `none:` / `error:` (schema) | #7 |
| `ExtConfigSchema` | `(s) → s` | `ok:<json-array>` of `{key,type,label,secret?,options?}` | #7 (schema backend) |
| `ExtGetConfig` | `(s) → s` | `ok:<json-object>` of current values | #7 |
| `ExtSetConfig` | `(s,s) → s` | save the JSON values | #7 |
| `GetHealthSummary` | `() → s` | `ok:` + 19 tab fields (today totals + week avgs + trends + resting/current HR + hrMin/hrMax + **hrAvailable** + lastSync) | #8 |
| `GetHealthSeries` | `(s) → as` | metric `steps`\|`sleep`\|`heart` → `label\tvalue`; **`heart` returns `[]` when HR unavailable** | #8 |
| `GetConfigSchema` | `() → as` | `key\ttype\tlabel\toptions\tdesc` | #10 |
| `GetConfig` | `() → as` | `key\tvalue` | #10 |
| `SetConfig` | `(s,s) → s` | set one config key | #10 |
| `NotifGetQuietHours` | `() → s` | `ok:<on\|off>\t<from>\t<to>\t<now\|off>` | new (notifications) |
| `NotifSetQuietHours` | `(b,s,s) → s` | enabled, from, to | new |
| `NotifSetQuietNow` | `(s) → s` | spec `1h`\|`morning`\|`off` | new |
| `NotifListFilters` | `() → as` | `pattern\taction` (`allow`\|`block`) | new |
| `NotifAddFilter` | `(s,s) → s` | pattern, action | new |
| `NotifRemoveFilter` | `(s) → s` | by pattern | new |

### Status-kind / shape notes
- `GetHealthSeries` rows use an **empty value field** to mark a no-data point (e.g. a future weekday);
  the shim maps that to `hasValue=false`.
- `ExtConfigSchema`/`ExtGetConfig` carry **JSON in the status tail** (the only place this contract uses
  JSON). Field types: `bool`/`string`(+`secret`)/`int`/`enum`(+`options`). Parsed in the shim, not QML.
- No new status *kinds* were needed; all hooks reuse `ok`/`error`/`notready`/`notfound`/`none`.

### Methods already in the 51, now wired (no drift)
`ListWatchPrefs`/`SetWatchPref` (Watch settings), `NotifList`/`NotifSetMute`/`NotifSetMuteAll`/
`NotifSetStyle` (per-app notifications), `StartDevConnection`/`StopDevConnection`/`DevConnectionStatus`
(dev toggle), `GetCoreDump` (Debug), `LaunchApp` (= set-active for a face). The mock now implements all
of these too (it previously covered only the Watch-screen subset).

---

## 2 · Confirmations requested (real method names)

- **set-active-face** → **no dedicated method**. Activating a watchface = **`LaunchApp(uuid|name)`** on a
  face; the daemon makes the launched face the active one (`LockerApi.activeWatchface`). The GUI calls
  `launchApp(uuid)` then re-reads `ListApps` and the `active` flag has moved. There is *no* `SetActiveFace`.
- **developer connection start** → **`StartDevConnection() → s` returns `ok:9000`** (LAN WebSocket on
  port 9000, binds `0.0.0.0`, **no auth**). Stop: `StopDevConnection() → s`. State:
  `DevConnectionStatus() → ok:active` / `ok:inactive` / `notready:`. The Watch-details toggle drives
  Start/Stop and seeds its initial value from `DevConnectionStatus`.
- **core dump** → **`GetCoreDump(s absPath) → s`** = `ok:<path>` / `none:` (no dump present) /
  `notready:` / `error:`. There is no standalone CLI verb (it's `support --coredump`). The GUI writes to
  a temp path and reports the result.
- **heart-rate availability** → **not exposed today**; the whole health series is hook #8, and HR is not
  even a tracked field in the daemon. The GUI depends on the new **`hrAvailable` flag in
  `GetHealthSummary`** and on `GetHealthSeries("heart")` returning `[]` when unavailable, and **hides the
  Heart-rate card** when absent (it does not fabricate data).
- **rename feasibility** → **feasible, wiring-only**. `KnownPebbleDevice.setNickname()` already exists
  (gap analysis, Screen 1). Exposed as **`SetWatchNickname(s watch, s nickname) → s`**; the Rename pencil
  is wired and functional against it. (If the daemon team declines to expose it, the pencil is the only
  thing to remove.)

---

## 3 · Hooks implemented vs deferred

**Implemented (mock + GUI):** #4 (transport, synced), #5 (GetSyncStatus/SetSyncEnabled), #7 (ext config —
both `url` and `schema` backends), #8 (health summary + series), #9 (SetWatchNickname), #10 (schema-driven
daemon config) — plus `WatchDetails`, the `CheckFirmware` changelog URL, the dev-connection wiring, and
the notification quiet-hours + regex-filter hooks.

**Deferred (the GUI ships on polling — handoff "when you want polling → live"):**
- #1 `WatchStateChanged`, #2 `FirmwareProgress`/`LanguageProgress`, #3 `LockerChanged`/
  `ExtensionStateChanged`. These are pure-wiring reactive upgrades. The GUI works today via the 4 s
  `ListWatches` focus poll, the Pair/Firmware/Language op-pollers, and the refresh-after-every-mutation
  rule. Landing the signals would let `StoandlClient` drop its timers; no UI change required.
- #6 byte-returning variants (`TakeScreenshotBytes`, `GatherLogsText`, `GetCoreDumpBytes`, `BackupTo`/
  `RestoreFrom`, `SupportBundle`) — not needed; the GUI is co-located with the daemon and uses the
  path-returning methods + the `stoandl` CLI for backup/restore/support.

---

## 4 · UX / layout findings & decisions

- **Re-pair dropped from the UI.** The by-the-book prototype has no re-pair affordance: known-watch rows
  are Connect + a forget bin, and the hero card opens the details dialog (Debug submenu + Forget, no
  re-pair). `Repair`/`PairStatus` plumbing stays in the shim if a future design wants it.
- **No Material FAB.** All "add/create" actions are Kirigami page actions (header on desktop, footer
  toolbar on mobile), per the handoff's repeated correction. The Apps install action is segment-aware.
- **Row actions are inline, not kebabs** everywhere (Apps/Faces gear+bin, Extensions toggle+gear+bin,
  known watches Connect+bin, notification filters bin).
- **States we can't yet detect.** The prototype's *Bluetooth-off* and *Reconnecting* states need
  `BluetoothStatus()`/`WatchStateChanged` (Screen-1 gaps) — not exposed, so not shown. The GUI does
  handle **daemon-down** (nav hidden + `systemctl --user start stoandl` affordance) and **no-watch**
  (`notready` → `PlaceholderMessage`).
- **Not readable from the daemon → kept as local UI state (flagged):** the per-app "Allow during quiet
  hours" priority override, and the master mute-all snooze state (`NotifSetMuteAll` has no getter; per-app
  mute is read back from `NotifList`).
- **Health `todayIndex`** isn't in the summary → derived as the last series point that has data.
- **Colors** (sleep stages, heart) are mapped to `Kirigami.Theme` roles; the prototype's fixed hexes are
  treated as a density spec, not a color spec (CLAUDE.md rule).
- **Quick-launch Up/Down** are rendered generically as enum `ListWatchPrefs` rows (no fabricated named
  rows), so they appear only if the daemon exposes them as prefs (the mock does).
- **Dev-box icon gap (not a styling bug):** `smartwatch-symbolic`, `heart-symbolic`, `battery-symbolic`
  are absent from this container's Breeze set but present on the Plasma Mobile target; semantic names are
  kept per the "environment gap, not a styling bug" rule.

---

## 5 · Verification

Built musl/glibc-agnostic with CMake/Ninja into an out-of-tree dir; the executable links clean. Every
screen was loaded against the mock on a private `dbus-run-session` bus (`tools/run-with-mock.sh`,
`QT_QPA_PLATFORM=offscreen`): **all five pages instantiate and pull live mock data with zero QML
warnings/errors.** Each mutation path re-fetches its list (signal-based for Apps/Extensions/Calendars/
Watches, direct re-read for Sync/Prefs/Config/Notifications).

An adversarial correctness pass (one reviewer per screen + one on shim/mock contract alignment) found and
fixed five real logic bugs before sign-off: a dead `disabled`-kind branch on Health sync (the daemon
signals disabled via `error:…not enabled`); the Notifications master-mute state was write-only and is now
derived from the per-app list; two Settings combo boxes bound the read-only `currentValue` instead of
`currentIndex` (so they showed the wrong selection); and the per-service "Sync now" buttons didn't refresh
the last-sync labels. The shim↔mock field-index/signature alignment reviewed clean.

**Screenshots:** not capturable in this headless container — there is no display server / `xvfb`, and the
Qt `offscreen` platform does not rasterize the scene graph for `grabToImage` (timers fire, but the grab
callback never does). Capture on a real display, or add `xvfb` + a software GL to `.container/Dockerfile`,
then run with `QT_QUICK_CONTROLS_MOBILE=1` and the `docs/handoff/BreezeDark-dev-preview.kdeglobals`
palette for the mobile + dark renders the design loop expects.
