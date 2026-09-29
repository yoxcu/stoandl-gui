# D-Bus interface

Both front-ends are clients of the daemon's `de.yoxcu.stoandl.Control` interface (session bus, name
`de.yoxcu.stoandl`, path `/de/yoxcu/stoandl`). Its contract (every method, the seven signals, the
tab-separated record layouts and the status-string conventions) is documented in one place, the daemon
repo's **`docs/dbus-interface.md`**:

- online: <https://github.com/yoxcu/stoandl/blob/main/docs/dbus-interface.md>
- from a daemon checkout, where this repo is the `gui/` submodule:
  [`../../docs/dbus-interface.md`](../../docs/dbus-interface.md)

The daemon keeps that document in sync with the interface declaration (`dbus/StoandlControl.kt`). This
file used to hold a copy, which drifted (it stopped at 51 of the 90 methods), so it now only points
there. `tools/mock_stoandl.py` follows the daemon's document and code too: when a reply changes, change
the mock to match.
