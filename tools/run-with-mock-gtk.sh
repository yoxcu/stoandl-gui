#!/usr/bin/env bash
# Launch the GTK4/libadwaita stoandl-gui against the mock daemon on a fresh,
# ephemeral session bus (GTK counterpart of run-with-mock.sh).
#
#   tools/run-with-mock-gtk.sh              # run the GUI (needs a Wayland display)
#   tools/run-with-mock-gtk.sh --headless   # smoke test under a headless weston
#   tools/run-with-mock-gtk.sh --mock-only  # just the mock (Ctrl-C to stop)
#
# Wayland-only, no X11 fallback. Build first: (cd gtk && cargo build).
# The GUI binary defaults to $CARGO_TARGET_DIR/debug/stoandl-gui-gtk (set in the
# Dockerfile to the persistent cache); override with $GUI.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
TARGET="${CARGO_TARGET_DIR:-$ROOT/gtk/target}"
GUI="${GUI:-$TARGET/debug/stoandl-gui-gtk}"
MOCK="$HERE/mock_stoandl.py"

if [[ "${1:-}" == "--mock-only" ]]; then
  exec dbus-run-session -- python3 "$MOCK"
fi

HEADLESS=0
if [[ "${1:-}" == "--headless" ]]; then
  HEADLESS=1
  shift
fi

if [[ ! -x "$GUI" ]]; then
  echo "error: $GUI not built — run: (cd gtk && cargo build)" >&2
  exit 1
fi

# weston (and Wayland clients) require XDG_RUNTIME_DIR.
if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
  XDG_RUNTIME_DIR="$(mktemp -d /tmp/stoandl-rt.XXXXXX)"
  chmod 700 "$XDG_RUNTIME_DIR"
  export XDG_RUNTIME_DIR
fi

# $0=_ $1=MOCK $2=GUI $3=HEADLESS $4..=GUI args
dbus-run-session -- bash -eo pipefail -c '
  mockpy="$1"; gui="$2"; headless="$3"; shift 3
  python3 "$mockpy" &
  mock=$!
  weston=""
  cleanup() {
    kill "$mock" 2>/dev/null || true
    [[ -n "$weston" ]] && kill "$weston" 2>/dev/null || true
  }
  trap cleanup EXIT

  # Wait (≤5 s) for the mock to claim the well-known name before starting the GUI.
  for _ in $(seq 1 50); do
    python3 -c "import dbus,sys; sys.exit(0 if dbus.SessionBus().name_has_owner(\"de.yoxcu.stoandl\") else 1)" 2>/dev/null && break
    sleep 0.1
  done

  if [[ "$headless" == "1" ]]; then
    # Headless Wayland compositor (no X11). Backend module name may vary by weston
    # version (headless-backend.so on 12/13); adjust if newer.
    weston --backend=headless-backend.so --socket=wayland-mock \
           --width=420 --height=760 >/tmp/weston-stoandl.log 2>&1 &
    weston=$!
    for _ in $(seq 1 50); do
      [[ -S "$XDG_RUNTIME_DIR/wayland-mock" ]] && break
      sleep 0.1
    done
    export WAYLAND_DISPLAY=wayland-mock GDK_BACKEND=wayland
    # Headless has no a11y bus and no GPU: silence the a11y-bus warning and force
    # the Cairo renderer so libEGL software-fallback noise does not mask real
    # GTK/Adwaita warnings in the smoke grep. Desktop runs are unaffected.
    # (NOTE: this whole -c script is single-quoted -- keep it apostrophe-free.)
    export GTK_A11Y=none GSK_RENDERER=cairo
    # Self-terminating: cycle every view_stack page, then quit (see window.rs).
    export STOANDL_SMOKE_MS="${STOANDL_SMOKE_MS:-300}"
  fi

  # Do NOT exec: exec would replace this shell and skip the EXIT trap, leaking
  # the mock + weston (their sockets survive and collide with the next run).
  "$gui" "$@"
  exit $?
' _ "$MOCK" "$GUI" "$HEADLESS" "$@"
