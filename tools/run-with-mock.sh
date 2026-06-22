#!/usr/bin/env bash
# Launch the GUI against the mock daemon on a fresh, ephemeral session bus.
#
#   tools/run-with-mock.sh                 # run the GUI normally
#   QT_QPA_PLATFORM=offscreen tools/run-with-mock.sh   # headless smoke test
#   tools/run-with-mock.sh --mock-only     # just run the mock (Ctrl-C to stop)
#
# Everything lives and dies with this process: dbus-run-session creates a private
# bus, we start the mock on it, then exec the GUI. On exit the bus is torn down.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
GUI="${GUI:-$ROOT/build/stoandl-gui}"
MOCK="$HERE/mock_stoandl.py"

if [[ "${1:-}" == "--mock-only" ]]; then
  exec dbus-run-session -- python3 "$MOCK"
fi

if [[ ! -x "$GUI" ]]; then
  echo "error: $GUI not built — run: cmake --build build" >&2
  exit 1
fi

# $0=_ $1=MOCK $2=GUI $3..=GUI args
dbus-run-session -- bash -eo pipefail -c '
  mockpy="$1"; gui="$2"; shift 2
  python3 "$mockpy" &
  mock=$!
  trap "kill $mock 2>/dev/null || true" EXIT
  # Wait (≤5 s) for the mock to claim the well-known name before starting the GUI.
  for _ in $(seq 1 50); do
    python3 -c "import dbus,sys; sys.exit(0 if dbus.SessionBus().name_has_owner(\"de.yoxcu.stoandl\") else 1)" 2>/dev/null && break
    sleep 0.1
  done
  exec "$gui" "$@"
' _ "$MOCK" "$GUI" "$@"
