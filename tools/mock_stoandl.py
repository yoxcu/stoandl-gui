#!/usr/bin/env python3
"""Mock of the stoandl daemon's de.yoxcu.stoandl.Control interface.

A stand-in for the real (JVM + BLE) daemon so the Kirigami GUI can be exercised
headlessly. It is STATEFUL: mutating calls update in-memory state, and the
long-running ops (Pair/Firmware/Language) walk pending -> terminal over a few
polls — so the GUI's "re-fetch after every mutation" path and the poll loops both
light up.

Covers every method either GUI calls: the daemon's whole de.yoxcu.stoandl.Control
except the CLI-only FakeCallRing/FakeCallEnd/ForceCoreDump/HeartRate/RunningApp,
plus the ExtCrash test hook. "HOOK #n" marks the methods the GUI work added to the
daemon. Returns follow the daemon's docs/dbus-interface.md, the one contract doc:
status strings are "kind:tail" with tab-separated fields; list methods return one
tab-joined record per element. Where the daemon's replies change, change the mock
to match rather than the GUI to match the mock.

Run inside a session bus, e.g.:  dbus-run-session -- python3 mock_stoandl.py
"""

import datetime
import json
import math
import os
import re
import struct
import time
import zlib

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

BUS_NAME = "de.yoxcu.stoandl"
OBJ_PATH = "/de/yoxcu/stoandl"
IFACE = "de.yoxcu.stoandl.Control"

# The numeric-comparison code surfaced as confirm:<code> until ConfirmPairing answers.
PAIR_CODE = "481516"

# The daemon's PairStatus notes for an open window that can't discover (PebbleIntegration's
# PAIRING_PAUSED_*): shown in place of the bare `pending:` and withdrawn again. MOCK_PAIR_PAUSE=<kind>
# shows one for the first polls of every pairing window.
PAIR_PAUSE_NOTES = {
    "bt": "Discovery paused — Bluetooth is off. Turn it on to pair.",
    "busy": "BLE scan paused — Time 2 is connecting (a scan would disturb it).",
    "slept": "Searching again — the phone slept, which pauses discovery. Keep it awake "
             "(e.g. the screen on) until the watch is found.",
}

# The older firmware MOCK_FW_DOWNGRADE=1 pretends every sideloaded .pbz carries. MOCK_FW_DOWNGRADE=drop
# is the same downgrade, but the watch comes back on its normal firmware instead of recovery, which the
# daemon reports as failed: (FirmwareControl's dropped downgrade).
DOWNGRADE_VERSION = "4.4.1"
DOWNGRADE_DROPPED = (f"failed:The watch came back on its normal firmware without the downgrade to "
                     f"{DOWNGRADE_VERSION}; sideload the .pbz again to retry")

# PebbleOS changelog (HOOK: appended to CheckFirmware so the GUI's "What's new" works).
CHANGELOG_URL = "https://ndocs.repebble.com/PebbleOS-Changelog-25efbb55ea84801da04bfcf73c9346e1"


def _png_gray(width, height, pixel):
    """A valid 8-bit greyscale PNG (pixel(x, y) -> 0..255), for the mock's screenshots."""
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))
    raw = b"".join(b"\0" + bytes(pixel(x, y) for x in range(width)) for y in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def rec(*fields):
    """Join fields into one tab-separated record (the `as` element format)."""
    return "\t".join(str(f) for f in fields)


# Column order of a GetConfigSchema record (see MockStoandl.config_schema).
CONFIG_COLS = ("key", "type", "label", "options", "desc", "group", "apply",
               "min", "max", "unit", "placeholder", "page", "help", "requires", "default", "egress")

# The daemon's GetConfigSchema rows, written by its ConfigSchemaTest (STOANDL_UPDATE_GOLDEN=1) with no
# speech models, voices or custom vibrations installed: the mock serves the real schema, never a hand copy.
CONFIG_SCHEMA_TSV = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config-schema.tsv")

# GetSyncStatus's `key` column (the daemon's SYNC_SERVICE_KEYS): SetSyncEnabled is an alias for SetConfig
# of this key, and the service is on exactly when the key is.
SYNC_SERVICE_KEYS = {
    "notifications": "notification.forward", "weather": "weather.enabled", "calendar": "calendar.enabled",
    "music": "music.enabled", "health": "health.sync", "dnd": "dnd.sync",
}


def _list_decode(raw):
    """The daemon's ConfList.decode: split on ',', with '\\,' a comma and '\\\\' a backslash inside an
    item (any other backslash literal); items trimmed, blank ones dropped."""
    items, cur, i = [], "", 0
    while i < len(raw):
        c, nxt = raw[i], raw[i + 1] if i + 1 < len(raw) else ""
        if c == "\\" and nxt in (",", "\\"):
            cur += nxt
            i += 1
        elif c == ",":
            items.append(cur)
            cur = ""
        else:
            cur += c
        i += 1
    items.append(cur)
    return [x.strip() for x in items if x.strip()]


def _list_encode(items):
    return ",".join(x.strip().replace("\\", "\\\\").replace(",", "\\,") for x in items if x.strip())


def _weather_locations(v):
    """The daemon's StoandlConfig.parseWeatherLocations: `(error, normalised)`. GetConfig reads each
    entry back with lat/lon printed like a Kotlin Double ("Home:48:11" -> "Home:48.0:11.0")."""
    out = []
    for entry in _list_decode(v):
        name, _, lon = entry.rpartition(":")
        name, _, lat = name.rpartition(":")
        try:
            lat, lon = float(lat), float(lon)
        except ValueError:
            name = ""
        if not name.strip():
            return "expected comma-separated Name:lat:lon entries (e.g. Berlin:52.52:13.405)", None
        out.append(f"{name.strip()}:{lat!r}:{lon!r}")
    return None, _list_encode(out)


def _github_repo_err(v):
    if v == "":
        return "cannot be empty (the default is coredevices/PebbleOS)"
    parts = v.split("/")
    ok = len(parts) == 2 and all(p.strip() and " " not in p for p in parts)
    return None if ok else "expected owner/repo (e.g. coredevices/PebbleOS)"


def _http_url_err(v):
    if v == "":
        return "cannot be empty"
    ok = v.startswith(("http://", "https://")) and " " not in v
    return None if ok else "expected an http:// or https:// URL"


# The daemon's per-key `validate` hooks in ConfigSchema.kt (text/list keys only), each as
# value -> (error or None, what GetConfig reads back afterwards).
CONFIG_CHECKS = {
    "weather.locations": _weather_locations,
    "firmware.github_repo": lambda v: (_github_repo_err(v), v),
    "firmware.cohorts_url": lambda v: (_http_url_err(v), v),
    "voice.url": lambda v: (_http_url_err(v) if v else None, v),
    "tts.url": lambda v: (_http_url_err(v) if v else None, v),
}

# Combo options whose stoandl.conf token (ConfigSchema.kt's ConfigChoice token) isn't the label
# lower-cased with '_' for spaces.
_ENGINE_TOKENS = {"Off": "off", "None": "off", "Local model": "local", "Custom command": "command", "HTTP service": "http"}
CONFIG_COMBO_TOKENS = {
    "notification.app_name": {"Small line": "small"},
    "notification.default_mute": {"Unmuted": "never", "Muted": "always", "Muted on weekdays": "weekdays",
                                  "Muted at weekends": "weekends"},
    "dnd.sync": {"Desktop → watch": "to_watch", "Watch → desktop": "to_host", "Both ways": "both"},
    "music.volume": {"System volume": "system", "Player volume": "player"},
    "weather.location_source": {"None": "manual", "GNOME Weather": "gnome", "A command": "command"},
    "voice.backend": _ENGINE_TOKENS,
    "voice.fallback_backend": _ENGINE_TOKENS,
    "tts.backend": _ENGINE_TOKENS,
    "plugins.permission_policy": {"When data could leave": "ask_if_exfiltrating", "Always": "always_ask", "Never": "never_ask"},
    "calendar.reminder_vibe": {"Watch default": ""},
}

# The daemon's WatchPrefText (pebble/WatchPrefText.kt): ListWatchPrefs' columns 8-10 (section, help,
# requires) for every pref libpebble3 knows, in display order, written by its WatchPrefTextTest
# (STOANDL_UPDATE_GOLDEN=1). An id not listed is in "Other", like a pref the daemon doesn't know yet.
WATCH_PREF_TEXT_TSV = os.path.join(os.path.dirname(os.path.abspath(__file__)), "watch-pref-text.tsv")
with open(WATCH_PREF_TEXT_TSV, encoding="utf-8") as _f:
    WATCH_PREF_TEXT = {r[0]: tuple(r[1:4]) for r in (line.rstrip("\n").split("\t") for line in _f if line.strip())}
WATCH_PREF_SECTIONS = list(dict.fromkeys(section for section, _, _ in WATCH_PREF_TEXT.values())) + ["Other"]

# WatchPrefsControl.allowed() for a quicklaunch pref: the firmware system actions (QuickLaunchActions,
# in the official app's order) between "off" and the app placeholder.
QL_ALLOWED = "off|Quiet Time|Backlight|Motion Backlight|Airplane Mode|Timeline Past|Timeline Future|<app name or uuid>"

class MockStoandl(dbus.service.Object):
    def __init__(self, bus, path):
        super().__init__(bus, path)
        # name -> {state, battery, transport, model, platform, firmware, serial,
        #          code, lastSync}. state in connected|connecting|disconnected.
        self.watches = {
            "Time Steel": {
                "state": "connected", "battery": "72", "transport": "classic",
                "model": "Pebble Time Steel", "platform": "BASALT", "firmware": "4.4.2",
                "serial": "Q402445E00GR", "code": "B349", "lastSync": "2 min ago",
            },
            "Time 2": {
                "state": "disconnected", "battery": "41", "transport": "ble",
                "model": "Pebble Time 2", "platform": "EMERY", "firmware": "4.4.2",
                "serial": "Q403118E01AA", "code": "A1F0", "lastSync": "yesterday",
            },
        }
        # MOCK_NO_WATCH=1 starts in the "paired but nothing connected" state, so the GUI's no-watch
        # paths (e.g. the watch-scoped rows on Settings → Diagnostics & developer) are testable without a Disconnect
        # method. It is a real state, not a flag: ListWatches and every "connected watch" method agree.
        if os.environ.get("MOCK_NO_WATCH") == "1":
            for w in self.watches.values():
                w["state"] = "disconnected"
        # Host Bluetooth on/usable (BluetoothStatus). Set False to exercise the GUI's BT-off state.
        self.bt_on = True
        # Disconnect(): the watch that was connected (resumed by Connect("")), or None. MOCK_LINK_PAUSE
        # starts with a pause: `manual`, `quiet_time` or both comma-separated.
        self.paused_watch = None
        self.link_pause = [p for p in os.environ.get("MOCK_LINK_PAUSE", "").split(",") if p]
        # Pairing op state: None when idle, else a dict tracking poll count.
        self.pairing = None
        # Locker contents (apps + faces). flags ⊆ {active,sideloaded,config,system,synced}.
        # HOOK #4: `synced` is now surfaced in the flags set.
        self.apps = [
            {"uuid": "8f3c8985", "type": "watchface", "order": 0,
             "flags": ["active", "system", "synced"], "title": "Tic Toc", "developer": "Pebble"},
            {"uuid": "3af56a2b", "type": "watchface", "order": 1,
             "flags": ["synced"], "title": "Isotime", "developer": "Pebble"},
            {"uuid": "d2cd8de2", "type": "watchface", "order": 2,
             "flags": ["synced"], "title": "Beam Up", "developer": "Pebble"},
            {"uuid": "5e5da3f1", "type": "watchface", "order": 3,
             "flags": ["config"], "title": "Kalk", "developer": "Vinch", "version": "2.4"},
            {"uuid": "1f03293d", "type": "watchapp", "order": 4,
             "flags": ["system", "synced"], "title": "Music", "developer": "Pebble"},
            {"uuid": "36d8c6ed", "type": "watchapp", "order": 5,
             "flags": ["system", "synced"], "title": "Health", "developer": "Pebble"},
            {"uuid": "07e0d9cb", "type": "watchapp", "order": 6,
             "flags": ["system", "synced"], "title": "Settings", "developer": "Pebble"},
            {"uuid": "a4d3f0b9", "type": "watchapp", "order": 7,
             "flags": ["sideloaded", "config", "synced"], "title": "Pebblemap", "developer": "katharostech", "version": "1.3.0"},
            {"uuid": "c91b77a0", "type": "watchapp", "order": 8,
             "flags": ["sideloaded"], "title": "Tezel", "developer": "lavers", "version": "0.9"},
        ]
        # Declared order of the built-in entries — the "system default" RestoreSystemAppOrder resets to.
        self._default_order = [a["uuid"] for a in self.apps]
        self._sideload_seq = 0
        # Extensions. HOOK #7: `config` (none|schema) + `description` + `author` + `version` + `stderr`.
        self.exts = [
            {"name": "Matrix", "installed": True, "enabled": True, "running": True,
             "config": "schema", "description": "Messages on the wrist + canned replies, E2EE",
             "author": "stoandl", "version": "1.0.0"},
            {"name": "Find My Phone", "installed": True, "enabled": True, "running": True,
             "config": "none", "description": "Ring this device from the watch",
             "author": "yoxcu", "version": "1.0.0"},
            {"name": "Signal", "installed": True, "enabled": False, "running": False,
             "config": "schema", "description": "Signal messages + quick replies",
             "author": "community", "version": "0.3.1"},
            {"name": "SMS Bridge", "installed": False, "enabled": False, "running": False,
             "config": "schema", "description": "Forward & reply to SMS over ModemManager"},
        ]
        self._ext_seq = 0
        # HOOK #7 (schema backend): per-extension typed config. schema = the manifest;
        # values = current settings. Two extensions declare config=schema above.
        self.ext_schema = {
            "Matrix": [
                {"key": "homeserver", "type": "string", "label": "Homeserver", "required": True},
                {"key": "user", "type": "string", "label": "User ID", "required": True},
                {"key": "password", "type": "string", "label": "Password", "secret": True},
            ],
            "Signal": [
                {"key": "phone", "type": "string", "label": "Linked phone number",
                 "description": "The number signal-cli is registered with",
                 "help": "Include the country code, e.g. +49 151 2345678. The extension only reads messages for this account."},
                {"key": "token", "type": "string", "label": "Device token", "secret": True},
                {"key": "interval", "type": "int", "label": "Poll interval (s)",
                 "help": "Shorter is faster but keeps the phone awake more often."},
                {"key": "replies", "type": "bool", "label": "Allow quick replies"},
                {"key": "groups", "type": "enum", "label": "Group chats", "options": ["all", "mentions", "none"]},
            ],
            "SMS Bridge": [
                {"key": "modem", "type": "enum", "label": "Modem", "options": ["ModemManager", "oFono"],
                 "description": "The telephony service that owns the modem"},
                {"key": "country", "type": "string", "label": "Default country code"},
                {"key": "delivery", "type": "bool", "label": "Delivery reports"},
            ],
        }
        self.ext_values = {
            "Matrix": {"homeserver": "https://matrix.example.org", "user": "@alice:example.org", "password": ""},
            "Signal": {"phone": "+1 555 0123", "token": "", "interval": 20, "replies": True, "groups": "mentions"},
            "SMS Bridge": {"modem": "ModemManager", "country": "+1", "delivery": False},
        }
        # HOOK #5: sync services — availability + last-sync. Whether one is on is its config key
        # (SYNC_SERVICE_KEYS, see _sync_on), as in the daemon.
        # service -> {available, lastSync}.
        self.sync = {
            "notifications": {"available": True, "lastSync": "live"},
            "weather": {"available": True, "lastSync": "8 min ago"},
            "calendar": {"available": True, "lastSync": "12 min ago"},
            "music": {"available": True, "lastSync": "live"},
            "health": {"available": True, "lastSync": "never"},
            "dnd": {"available": True, "lastSync": "off"},
        }
        # Live now-playing surfaced on the Music sync row (MusicStatus). player="" → idle → the
        # row falls back to its "Last sync · …" subtitle.
        self._music = {"playing": True, "player": "Spotify",
                       "track": "Alice Coltrane — Journey in Satchidananda"}
        # Editable calendar sources (ListCalendarSources) + the discovered calendars they fan out to
        # (ListCalendars, each tagged with its owning source's id via accountId).
        self.calendar_sources = [
            {"id": "caldav:ab12cd34", "type": "caldav",
             "url": "https://dav.example.com/alice/", "username": "alice", "label": "dav.example.com",
             "lastSync": int(time.time()) - 600},
            {"id": "ical:https://cal.example.com/feed.ics", "type": "ical",
             "url": "https://cal.example.com/feed.ics", "username": "", "label": "cal.example.com",
             "lastError": "Sign-in failed (401)"},
        ]
        self._caldav_next = 1  # to mint new caldav tokens deterministically
        self.calendars = [
            {"id": "personal@local", "name": "Personal", "enabled": True,  "accountId": "caldav:ab12cd34"},
            {"id": "work@corp",      "name": "Work",     "enabled": True,  "accountId": "caldav:ab12cd34"},
            {"id": "holidays@public","name": "Holidays", "enabled": False, "accountId": "ical:https://cal.example.com/feed.ics"},
        ]
        # Watch advanced settings (ListWatchPrefs / SetWatchPref). This MIRRORS the real daemon's
        # WatchPrefsControl.list() record EXACTLY so the GUI is exercised against the true contract:
        #   id \t type \t current \t default \t allowed \t flags \t name \t description
        # type ∈ {bool, number, enum, quicklaunch, color, schedule}; `allowed` is PIPE-separated (the
        # real daemon joins option/range lists with '|', NOT ','); enum current/allowed use DISPLAY
        # names; number current/default carry the unit ("3000 ms"); quicklaunch current is an app name
        # / "off" / a raw uuid; color is "0xRRGGBB"; schedule is a 24 h "HH:MM-HH:MM" window (allowed is
        # that literal); flags carries "debug" for advanced/debug-only prefs. The ids match libpebble3's
        # WatchPref ids so the GUI's category grouping (keyed on id) applies. The daemon lists prefs in
        # libpebble3's enumeratePrefs() order (bools first, the schedules LAST), not by section — the
        # schedules are at the end here too, so the GUIs' "hours follow their Enabled switch" ordering
        # is exercised.
        self.prefs = [
            # --- Quick Launch (quicklaunch: a system action, an app name or "off") ---
            {"id": "qlUp", "type": "quicklaunch", "current": "Music", "default": "off",
             "allowed": QL_ALLOWED, "flags": "",
             "name": "Quick Launch: Hold Up", "description": "App launched by a long up-press"},
            {"id": "qlDown", "type": "quicklaunch", "current": "off", "default": "off",
             "allowed": QL_ALLOWED, "flags": "",
             "name": "Quick Launch: Hold Down", "description": "App launched by a long down-press"},
            {"id": "qlSelect", "type": "quicklaunch", "current": "off", "default": "off",
             "allowed": QL_ALLOWED, "flags": "",
             "name": "Quick Launch: Hold Select", "description": "App launched by a long select-press"},
            {"id": "qlSingleClickUp", "type": "quicklaunch", "current": "Health", "default": "Health",
             "allowed": QL_ALLOWED, "flags": "",
             "name": "Quick Launch: Tap Up", "description": "App launched by a tap of the up button"},
            {"id": "qlBack", "type": "quicklaunch", "current": "Quiet Time", "default": "Quiet Time",
             "allowed": QL_ALLOWED, "flags": "",
             "name": "Quick Launch: Hold Back", "description": ""},
            # --- Display & Backlight ---
            {"id": "lightEnabled", "type": "bool", "current": "true", "default": "true",
             "allowed": "true|false", "flags": "", "name": "Backlight",
             "description": "Light the screen on button press"},
            {"id": "lightMotion", "type": "bool", "current": "true", "default": "true",
             "allowed": "true|false", "flags": "", "name": "Backlight Motion",
             "description": "Turn on backlight by flicking wrist"},
            {"id": "lightPreset", "type": "enum", "current": "Standard", "default": "Standard",
             "allowed": "Max Brightness|Standard|Battery Saver|Advanced", "flags": "",
             "name": "Backlight Preset",
             "description": "Bundles the ambient sensor, dynamic backlight, brightness and timeout into one mode. Choose Advanced to configure them individually."},
            {"id": "lightDynamicMode", "type": "enum", "current": "Standard", "default": "Standard",
             "allowed": "Off|Bright|Standard|Dim", "flags": "", "name": "Dynamic Backlight",
             "description": "Automatically adjust backlight brightness to match your environment (using light sensor). Dimmer modes stay dimmer in bright light."},
            {"id": "lightIntensity", "type": "enum", "current": "Medium", "default": "Medium",
             "allowed": "Low|Medium|High|Blinding", "flags": "", "name": "Backlight Intensity",
             "description": "Maximum backlight brightness when on"},
            {"id": "lightTimeoutMs", "type": "number", "current": "3000 ms", "default": "3000 ms",
             "allowed": "1..10000 ms", "flags": "", "name": "Backlight Timeout",
             "description": "How long the backlight stays on"},
            {"id": "lightColor", "type": "color", "current": "0xFFBFA2", "default": "0xFFBFA2",
             "allowed": "RRGGBB|Red|Orange|Yellow|Lime|Green|Cyan|Blue|Purple|Magenta|Pink|Warm White|Cool White",
             "flags": "", "name": "Backlight Color",
             "description": "LED color used when the backlight is on (color watches only)"},
            # The two text sizes keep libpebble3's descriptions; the daemon renames them (both are "Text
            # Size" upstream) and moves its firmware note into the help column (watch-pref-text.tsv).
            {"id": "systemTextSize", "type": "enum", "current": "Default", "default": "Default",
             "allowed": "Smaller|Default|Larger", "flags": "", "name": "Menu Text Size",
             "description": "Text size in menus and the system UI"},
            {"id": "notifTextSize", "type": "enum", "current": "Default", "default": "Default",
             "allowed": "Smaller|Default|Larger", "flags": "", "name": "Notification Text Size",
             "description": "Text size of notifications"},
            {"id": "lightAmbientThreshold", "type": "number", "current": "200", "default": "150",
             "allowed": "1..4096", "flags": "debug", "name": "Ambient Light Threshold",
             "description": "How low ambient light must be to enable the backlight"},
            {"id": "displayOrientationLeftHanded", "type": "bool", "current": "false", "default": "false",
             "allowed": "true|false", "flags": "", "name": "Left-handed Mode",
             "description": "Button functions are reversed"},
            # --- Notifications ---
            {"id": "mask", "type": "enum", "current": "All On", "default": "All On",
             "allowed": "All On|Phone Calls|All Off", "flags": "", "name": "Notification Filter",
             "description": ""},
            {"id": "notifWindowTimeout", "type": "number", "current": "180000 ms", "default": "180000 ms",
             "allowed": "15000..600000 ms", "flags": "", "name": "Notification Timeout",
             "description": "Notifications time out after this period (unless in Quiet Time)"},
            {"id": "timelineQuickViewEnabled", "type": "bool", "current": "true", "default": "true",
             "allowed": "true|false", "flags": "", "name": "Timeline Quick View",
             "description": "Show upcoming events below the watchface"},
            # --- Quiet Time ---
            {"id": "dndManuallyEnabled", "type": "bool", "current": "false", "default": "false",
             "allowed": "true|false", "flags": "", "name": "Quiet Time - Manual",
             "description": "Mute notifications and keep them on-screen without a timeout"},
            {"id": "dndWeekdayScheduleEnabled", "type": "bool", "current": "false", "default": "false",
             "allowed": "true|false", "flags": "", "name": "Quiet Time - Weekday Schedule",
             "description": "Automatically enable Quiet Time during the scheduled hours, Monday to Friday"},
            {"id": "dndWeekendScheduleEnabled", "type": "bool", "current": "false", "default": "false",
             "allowed": "true|false", "flags": "", "name": "Quiet Time - Weekend Schedule",
             "description": "Automatically enable Quiet Time during the scheduled hours, Saturday and Sunday"},
            {"id": "dndShowNotifications", "type": "enum", "current": "Show", "default": "Show",
             "allowed": "Hide|Show", "flags": "", "name": "Quiet Time - Show Notifications",
             "description": ""},
            # --- Vibration ---
            {"id": "vibeIntensity", "type": "enum", "current": "High", "default": "High",
             "allowed": "Low|Medium|High", "flags": "", "name": "System Vibration Intensity",
             "description": ""},
            {"id": "vibeScoreNotifications", "type": "enum", "current": "Nudge Nudge", "default": "Nudge Nudge",
             "allowed": "Disabled|Standard - Low|Standard - High|Pulse|Nudge Nudge|Jackhammer|Mario",
             "flags": "", "name": "Vibration - Notifications", "description": ""},
            # --- Music ---
            {"id": "musicShowVolumeControls", "type": "bool", "current": "true", "default": "true",
             "allowed": "true|false", "flags": "", "name": "Show Volume Controls",
             "description": ""},
            # --- Motion & Menus ---
            {"id": "motionSensitivity", "type": "enum", "current": "Medium", "default": "Medium",
             "allowed": "Very Low|Low|Medium-Low|Medium|Medium-High|High|Very High", "flags": "debug",
             "name": "Motion Sensitivity", "description": ""},
            {"id": "menuScrollWrapAround", "type": "bool", "current": "false", "default": "false",
             "allowed": "true|false", "flags": "", "name": "Menu Scrolling - Wrap Around",
             "description": "Up button will go to the bottom of menus"},
            # --- Clock & Language ---
            {"id": "clock24h", "type": "bool", "current": "false", "default": "false",
             "allowed": "true|false", "flags": "", "name": "24h clock", "description": ""},
            {"id": "language", "type": "enum", "current": "Custom (Language Pack)",
             "default": "Custom (Language Pack)",
             "allowed": "Custom (Language Pack)|English",
             "flags": "", "name": "Language",
             "description": "Built-in firmware language. Choose Custom to use an uploaded language pack."},
            # --- no section of its own (lands in "Other") ---
            {"id": "unitsWind", "type": "enum", "current": "Automatic", "default": "Automatic",
             "allowed": "Automatic|km/h|mph", "flags": "", "name": "Wind Speed",
             "description": "Automatic follows the Imperial Units setting."},
            # --- Quiet Time hours (schedule), last like the daemon's enumeratePrefs() order ---
            {"id": "dndWeekdaySchedule", "type": "schedule", "current": "00:00-06:00",
             "default": "00:00-06:00", "allowed": "HH:MM-HH:MM", "flags": "",
             "name": "Quiet Time - Weekday Hours", "description": ""},
            {"id": "dndWeekendSchedule", "type": "schedule", "current": "00:00-06:00",
             "default": "00:00-06:00", "allowed": "HH:MM-HH:MM", "flags": "",
             "name": "Quiet Time - Weekend Hours", "description": ""},
        ]
        # System screen: firmware + language op state, language catalog.
        self.fw = None    # None when idle, else the walk (see _fw_steps / _start_fw_push)
        self.lang = None  # None when idle, else {"polls": n, "name": ...}
        self.languages = [
            {"id": "en_US", "iso": "English (US)", "name": "English (US)", "installed": True,  "source": "github"},
            {"id": "de_DE", "iso": "Deutsch",      "name": "German",       "installed": False, "source": "rebble"},
            {"id": "fr_FR", "iso": "Francais",     "name": "French",       "installed": False, "source": "rebble"},
            {"id": "ja_JP", "iso": "Nihongo",      "name": "Japanese",     "installed": False, "source": "github"},
        ]
        # HOOK #10: daemon config (stoandl.conf) over D-Bus, schema-driven: the daemon's own GetConfigSchema
        # rows (CONFIG_SCHEMA_TSV), and its defaults (the `default` column) as the current values, plus a
        # sample weather location. Columns past the original five were appended; a client that reads only
        # the first five still works, which is exactly what this mock lets you check.
        with open(CONFIG_SCHEMA_TSV, encoding="utf-8") as f:
            self.config_schema = [dict(zip(CONFIG_COLS, line.rstrip("\n").split("\t"))) for line in f if line.strip()]
        self.config = {c["key"]: c["default"] for c in self.config_schema}
        self.config["weather.locations"] = "Berlin:52.52:13.405"
        # HOOK #8: health. Per-day data is GENERATED deterministically from each date's ordinal
        # (see the _*_for/_window helpers) so the period-aware GetHealthSummary/GetHealthSeries
        # (day/week/month + offset) all light up with realistic multi-day data. Global flags only:
        self.health = {
            "hrAvailable": "yes",
            "sleepTypicalMin": 426,     # 30-day typical sleep (constant)
            "lastSync": "2 min ago",
        }
        # The watch's own health-tracking config (write side: the Health-profile settings
        # sub-page via GetHealthProfile/SetHealthProfile). Keyed key→value strings.
        self.health_profile = {
            "height_cm": "178",
            "weight_kg": "74",
            "age": "31",
            "gender": "other",
            "units": "metric",
            "tracking": "on",
            "activity_insights": "on",
            "sleep_insights": "on",
            "hrm": "on",
            "hrm_interval": "10min",
            "hrm_activity": "off",
            "resting_hr": "58",
            "max_hr": "189",
        }
        # Notifications (per-app store; master forwarding is config notification.forward). `app_name` is the
        # per-app notification.app_name override (small|subtitle|off), "" = follows the global setting.
        self.notif_apps = [
            {"name": "Signal",   "mute": "never",  "color": "default", "icon": "default", "vibe": "Double",   "last": 1718900000, "app_name": ""},
            {"name": "Matrix",   "mute": "weekdays", "color": "default", "icon": "default", "vibe": "Standard", "last": 1718901200, "app_name": ""},
            {"name": "Gmail",    "mute": "never",  "color": "default", "icon": "default", "vibe": "Subtle",   "last": 1718890000, "app_name": "subtitle"},
            {"name": "Phone",    "mute": "never",  "color": "default", "icon": "default", "vibe": "Long",     "last": 1718880000, "app_name": "off"},
            {"name": "Calendar", "mute": "always", "color": "default", "icon": "calendar","vibe": "Standard", "last": 1718800000, "app_name": ""},
        ]
        # HOOK (notifications): regex filters (config-backed today).
        self.filters = [
            {"pattern": "(?i)verification code", "action": "allow"},
            {"pattern": "Slack: .* is typing", "action": "block"},
        ]
        # Developer connection (StartDevConnection / Stop / Status).
        self.dev_active = False

    # --- helpers -----------------------------------------------------------
    def _connected_name(self):
        for name, w in self.watches.items():
            if w["state"] == "connected":
                return name
        return None

    def _reachable_name(self):
        """The watch the daemon's firmware, core-dump and logs methods act on: a connected one, or
        one connected in its recovery firmware (ListWatches `recovery`), which nothing else serves."""
        for name, w in self.watches.items():
            if w["state"] in ("connected", "recovery"):
                return name
        return None

    def _resolve_connected(self, query):
        """The daemon's resolveWatch() for the battery/heartbeat methods: a blank query is the connected
        watch; otherwise a CONNECTED watch matching by exact-then-substring name. None when no connected
        watch matches — the daemon then has no serial, so no heartbeat data and at most a GATT series."""
        name = self._connected_name()
        if name is None:
            return None
        if not query or query.lower() == name.lower() or query.lower() in name.lower():
            return name
        return None

    def _set_connected(self, name):
        for n, w in self.watches.items():
            w["state"] = "connected" if n == name else "disconnected"
        if name in self.watches and not self.watches[name]["battery"]:
            self.watches[name]["battery"] = "88"
        # Push: connect/disconnect/pair-completion all funnel through here.
        self.WatchesChanged()

    # --- ListWatches / Battery / WatchDetails ------------------------------
    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def BluetoothStatus(self):
        # Host Bluetooth on/usable. Flip self.bt_on (or send SIGUSR-style toggle) to
        # exercise the GUI's Bluetooth-off state.
        return "ok:on" if self.bt_on else "ok:off"

    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def ListWatches(self):
        # HOOK #4: `transport` (ble|classic, empty when disconnected) appended. State `recovery` is a
        # watch connected in its recovery firmware; battery and transport are known for it too.
        live = ("connected", "recovery")
        return [rec(n, w["state"], w["battery"] if w["state"] in live else "",
                    w["transport"] if w["state"] in live else "")
                for n, w in self.watches.items()]

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def Battery(self):
        name = self._connected_name()
        if name is None:
            return "notready:No watch connected"
        level = self.watches[name]["battery"] or "0"
        return f"ok:{rec(name, level)}"

    # --- Battery insights (BatteryHistory / Insights / Activity / Power) ----
    def _battery_points(self, since, now):
        """A plausible hourly discharge curve: recharge overnight (00:00-06:00) then discharge
        through the day. Each point is [ts, level, charging, voltage] (soc + volts)."""
        step = 3600
        pts = []
        t = int(since) - (int(since) % step)
        while t <= now:
            day_pos = (t % 86400) / 86400.0
            if day_pos < 0.25:
                level = 60.0 + (day_pos / 0.25) * 40.0            # 60 -> 100 (on charger)
                charging = True
            else:
                level = 100.0 - ((day_pos - 0.25) / 0.75) * 70.0  # 100 -> 30 (discharging)
                charging = False
            volt = round(3.55 + (level / 100.0) * 0.65, 3)        # ~3.55 .. 4.20 V
            pts.append([t, round(level, 2), charging, volt])
            t += step
        return pts

    @dbus.service.method(IFACE, in_signature="sx", out_signature="s")
    def BatteryHistory(self, watch, sinceEpoch):
        # Like the daemon, no connected watch is not an error: it falls back to the (here empty) GATT
        # level series of the query, so `ok:` with no rows. notready: only means capture is off.
        name = self._resolve_connected(watch)
        if name is None:
            return "ok:"
        now = int(time.time())
        pts = self._battery_points(int(sinceEpoch), now)
        return "ok:" + "\n".join(rec(p[0], p[1], "heartbeat", p[3]) for p in pts)

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def BatteryInsights(self, watch):
        name = self._resolve_connected(watch)
        if name is None:
            return f"unknown:{watch or 'watch'}"
        now = int(time.time())
        pts = self._battery_points(now - 7 * 86400, now)
        if len(pts) < 2:
            return f"unknown:{name}"
        last = pts[-1]
        level, charging, volt = last[1], last[2], last[3]
        day = [p for p in pts if p[0] >= now - 86400]
        drop = secs = 0.0
        for i in range(1, len(day)):
            dl = day[i][1] - day[i - 1][1]
            dt = day[i][0] - day[i - 1][0]
            if dl < 0 and dt > 0:
                drop += -dl
                secs += dt
        rate = drop / (secs / 3600.0) if secs > 0 else 0.0
        hours = "" if (charging or rate <= 0) else f"{level / rate:.1f}"
        sessions = 0
        in_charge = False
        last_charged = -1
        for p in pts:
            if p[2]:
                if not in_charge:
                    sessions += 1
                    in_charge = True
                last_charged = p[0]
            else:
                in_charge = False
        mn = min(p[1] for p in day)
        mx = max(p[1] for p in day)
        return "ok:" + rec(name, round(level, 2), 1 if charging else 0, f"{rate:.2f}", hours,
                           sessions, last_charged, round(mn, 2), round(mx, 2), len(pts), volt, "heartbeat")

    @dbus.service.method(IFACE, in_signature="sx", out_signature="s")
    def BatteryActivity(self, watch, sinceEpoch):
        # Per-interval drop + notification counts (deterministic, hour-of-day shaped).
        if self._resolve_connected(watch) is None:
            return "ok:"
        now = int(time.time())
        pts = self._battery_points(int(sinceEpoch), now)
        rows = []
        for i in range(1, len(pts)):
            dl = pts[i - 1][1] - pts[i][1]                       # positive = discharge
            drop = round(dl, 2) if dl > 0 else 0.0
            hod = (pts[i][0] % 86400) // 3600                    # 0..23
            notif = ((hod * 3) % 7) if 7 <= hod <= 23 else 0     # awake-hours notifications
            notif_dnd = notif if hod >= 22 else 0
            rows.append(rec(pts[i][0], drop, notif, notif_dnd))
        return "ok:" + "\n".join(rows)

    @dbus.service.method(IFACE, in_signature="sx", out_signature="s")
    def BatteryPower(self, watch, sinceEpoch):
        # Battery-drain attribution (estimate): category\testDrainPct\tsharePct, largest share first.
        # Fixed illustrative split (weights sum to 1.0). estDrainPct = total_drop × weight (slices sum
        # to the measured discharge → drain-anchored; 0 when the window never discharged); sharePct =
        # weight × 100 (the pie wedge). "System" is the always-on floor slice.
        if self._resolve_connected(watch) is None:
            return "ok:"             # the daemon's answer for a watch without heartbeat data
        now = int(time.time())
        pts = self._battery_points(int(sinceEpoch), now)
        total_drop = sum(max(0.0, pts[i - 1][1] - pts[i][1]) for i in range(1, len(pts)))
        weights = [("System", 0.34), ("Display", 0.18), ("Bluetooth", 0.14), ("CPU", 0.13),
                   ("Heart rate", 0.11), ("Vibration", 0.06), ("Speaker", 0.04)]
        body = "\n".join(rec(cat, round(total_drop * w, 2), round(w * 100.0, 1)) for cat, w in weights)
        return "ok:" + body

    # --- Debug → Heartbeat -------------------------------------------------
    # The raw hourly analytics record (native_heartbeat_record) decoded in full. See
    # docs/heartbeat-metrics.md in the daemon repo for the metric map. Set
    # MOCK_HB_UNKNOWN=1 to exercise the "unverified layout" state (known=0, no metrics).

    @staticmethod
    def _fmt_num(d):
        # The daemon's fmtNum(): an integer when whole, else two decimals.
        return str(int(d)) if d == int(d) else f"{d:.2f}"

    def _heartbeat_metrics(self):
        # The whole record of a fw >= 4.33 watch (567 B / v3, unchanged through 4.38.2): its 101 metrics
        # in wire order (analytics.def declaration order, the daemon's HeartbeatLayouts.METRICS), so
        # every group the Heartbeat page can meet appears — including v3's unexpected_/i2c_/drv_.
        # Built the way HeartbeatMetrics() formats them: `value` = raw / scale through fmtNum (so
        # 3919/1000 is "3.92", not "3.919"), `raw` the undivided wire integer, `text` only for strings.
        def num(name, raw, scale=1):
            return (name, self._fmt_num(raw / scale), "", str(raw))

        def txt(name, text):
            return (name, "", text, "")

        return [
            num("memory_pct_max", 62), num("memory_largest_free_pct", 31),
            num("stack_free_kernel_main_bytes", 1840), num("stack_free_kernel_background_bytes", 1112),
            num("stack_free_newtimers_bytes", 604), num("stack_free_app_syscall_bytes", 1432),
            num("stack_free_worker_syscall_bytes", 1500), num("utc_offset_s", 7200),
            txt("fw_version", "v4.38.2"), num("last_reboot_reason", 0), num("uptime_s", 268400),
            num("battery_soc_pct", 7250, 100), num("battery_soc_pct_drop", 120, 100),
            num("battery_voltage", 3919, 1000), num("battery_voltage_delta", -12, 1000),
            num("battery_tte_s", 828000), num("battery_charge_time_ms", 0),
            num("battery_discharge_duration_ms", 3600000), num("backlight_on_time_ms", 42000),
            num("backlight_avg_intensity_pct", 60), num("vibrator_on_time_ms", 1200),
            num("vibrator_avg_strength_pct", 80), num("speaker_on_time_ms", 0), num("speaker_play_count", 0),
            num("speaker_avg_volume_pct", 0), num("speaker_preempted_count", 0),
            num("speaker_stream_underrun_count", 0), num("hrm_on_time_ms", 90000),
            num("button_pressed_count", 37), num("touch_event_count", 112), num("gesture_tap_count", 3),
            num("gesture_double_tap_count", 1), num("touch_driver_wake_cnt", 9),
            num("cpu_running_pct", 1240, 100), num("cpu_sleep0_pct", 6120, 100),
            num("cpu_sleep1_pct", 2410, 100), num("cpu_sleep2_pct", 230, 100),
            num("sifli_ipc_not_idle_count", 0), num("task_cpu_kernel_main_pct", 310, 100),
            num("task_cpu_kernel_background_pct", 45, 100), num("task_cpu_worker_pct", 0, 100),
            num("task_cpu_app_pct", 240, 100), num("task_cpu_bt_host_pct", 190, 100),
            num("task_cpu_bt_controller_pct", 120, 100), num("task_cpu_bt_hci_pct", 30, 100),
            num("task_cpu_new_timers_pct", 20, 100), num("task_cpu_pulse_pct", 5, 100),
            num("task_cpu_idle_pct", 9040, 100), num("accel_sample_count", 180000), num("accel_shake_count", 4),
            num("accel_double_tap_count", 0), num("accel_peek_count", 2),
            num("notification_received_count", 12), num("notification_received_dnd_count", 3),
            num("phone_call_incoming_count", 1), num("phone_call_time_ms", 154000), num("low_power_time_ms", 0),
            num("stationary_time_ms", 2400000), num("watchface_time_ms", 3210000),
            txt("watchface_name", "Tezel"), txt("watchface_uuid", "c91b77a0-1e2f-4c3d-9a5b-6d7e8f901234"),
            num("watchface_crash_count", 0), num("watchface_crash_revert_count", 0),
            num("pfs_space_free_kb", 1284), num("flash_spi_write_bytes", 98304),
            num("flash_spi_erase_bytes", 65536), num("ble_adv_short_intvl_time_ms", 0),
            num("ble_adv_long_intvl_time_ms", 0), num("ble_conn_itvl_min_time_ms", 60000),
            num("ble_conn_itvl_mid_time_ms", 240000), num("ble_conn_itvl_max_time_ms", 3100000),
            num("ble_disconnect_conn_spvn_tmo_count", 3), num("ble_disconnect_rem_user_term_count", 1),
            num("ble_disconnect_conn_term_local_count", 0), num("ble_disconnect_lmp_ll_rsp_tmo_count", 0),
            num("ble_disconnect_conn_establishment_count", 0), num("ble_disconnect_other_count", 0),
            num("ppog_reversed", 0), num("settings_health_tracking_enabled", 1),
            num("settings_health_hrm_enabled", 1), num("settings_health_hrm_measurement_interval", 10),
            num("settings_health_hrm_activity_tracking_enabled", 1), num("settings_motion_sensitivity", 50),
            num("settings_backlight_intensity_pct", 50), num("settings_backlight_timeout_s", 5),
            num("settings_touch_enabled", 1), num("app_message_sent_count", 204),
            num("app_message_received_count", 198), num("app_tick_timer_second_subscribed", 0),
            num("connectivity_connected_time_ms", 3400000), num("connectivity_expected_time_ms", 3600000),
            num("ble_conn_slave_lat0_time_ms", 180000), num("ble_conn_param_update_count", 4),
            num("accel_stream_recovery_count", 0), num("unexpected_reboot_count", 0),
            num("battery_temp_c", 27500, 1000), num("i2c_transfer_error_count", 0),
            num("ble_conn_itvl_other_time_ms", 200000), num("drv_init_fail_flags", 0),
            num("battery_soc_pct_min", 7150, 100), num("touch_gated_touchdown_count", 6),
        ]

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def HeartbeatInfo(self, watch):
        # ok:watchTs\trx\tsize\tversion\tbuildId\tfw\tknown\tmetricCount
        # Like the daemon, this reads the stored record of a CONNECTED watch only (its
        # resolveWatch() matches connected devices): with none matching it answers
        # unknown:<the query, or "watch">, whatever is on disk.
        if self._resolve_connected(watch) is None:
            return f"unknown:{watch or 'watch'}"
        now = int(time.time())
        ts = now - (now % 3600)
        build = "1a1f6be63bcc7823adfc00ea9d05012478e6ad44"
        if os.environ.get("MOCK_HB_UNKNOWN") == "1":
            # A layout stoandl hasn't verified yet (a firmware newer than its table).
            return "ok:" + rec(ts, ts + 60, 575, 4, build, "v4.39.0", 0, 0)
        m = self._heartbeat_metrics()
        return "ok:" + rec(ts, ts + 60, 567, 3, build, "v4.38.2", 1, len(m))

    @dbus.service.method(IFACE, in_signature="s", out_signature="as")
    def HeartbeatMetrics(self, watch):
        if self._resolve_connected(watch) is None or os.environ.get("MOCK_HB_UNKNOWN") == "1":
            return []
        return [rec(*row) for row in self._heartbeat_metrics()]

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def WatchDetails(self):
        # HOOK (identity): structured details for the connected watch — the fields
        # the Watch-details dialog shows. Board intentionally omitted (handoff §4d).
        # ok:name\tcode\tmodel\tplatform\ttransport\tfirmware\tserial\tbattery\tlastSync
        name = self._connected_name()
        if name is None:
            return "notready:"
        w = self.watches[name]
        transport = "Bluetooth Classic" if w["transport"] == "classic" else "Bluetooth LE"
        return "ok:" + rec(name, w["code"], w["model"], w["platform"], transport,
                           w["firmware"], w["serial"], w["battery"], w["lastSync"])

    # --- Connect -----------------------------------------------------------
    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def Connect(self, name):
        if name == "":
            was = "manual" in self.link_pause
            self.link_pause = [p for p in self.link_pause if p != "manual"]
            if self.paused_watch is not None:
                self._set_connected(self.paused_watch)
                self.paused_watch = None
            else:
                self.WatchesChanged()
            return "ok:Watch connection resumed" if was else "ok:Watch connection wasn't paused"
        match = self._resolve(name)
        if match is None:
            return f"notfound:no known watch matching '{name}'"
        self.link_pause = [p for p in self.link_pause if p != "manual"]
        self.paused_watch = None
        self._set_connected(match)
        return f"ok:connected to {match}"

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def Disconnect(self):
        if "manual" in self.link_pause:
            return "ok:Watch connection already paused"
        self.link_pause.append("manual")
        self.paused_watch = self._connected_name()
        self._set_connected(None)
        return "ok:Watch connection paused — 'stoandl watch connect' resumes it"

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def LinkPause(self):
        return "ok:" + ",".join(self.link_pause)

    def _resolve(self, query):
        if query in self.watches:
            return query
        hits = [n for n in self.watches if query.lower() in n.lower()]
        return hits[0] if len(hits) == 1 else None

    # --- Pair / PairStatus / Repair / Unpair -------------------------------
    # The daemon's walk: bare `pending:` while searching (or a pause note, see PAIR_PAUSE_NOTES) ->
    # `pending:Found <watch> — pairing...` -> `confirm:<code>` until ConfirmPairing answers ->
    # `pending:Completing pairing…` -> `ok:Paired and connected`. A decline ends the window with
    # `error:Pairing declined`. Like the daemon, Pair() opens a window while a watch is connected too (to
    # pair a second one), and the new watch takes the one link over.
    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def Pair(self):
        self._open_pairing("Pebble (new)", None)
        return "ok:Pairing started"

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def Repair(self, name):
        match = self._resolve(name)
        if match is None:
            return f"notfound:no known watch matching '{name}'"
        info = self.watches.pop(match)
        info["state"] = "disconnected"
        self._open_pairing(match, info)
        return f"ok:Re-pairing {match} — put the watch in pairing mode"

    def _open_pairing(self, new_name, restore):
        self.pairing = {"phase": "search", "polls": 0, "newName": new_name, "restore": restore,
                        "decision": None, "pause": PAIR_PAUSE_NOTES.get(os.environ.get("MOCK_PAIR_PAUSE", ""))}

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def PairStatus(self):
        p = self.pairing
        if p is None:
            return "error:No pairing in progress"
        if p["phase"] == "result":
            return p["result"]          # the daemon keeps reporting the outcome until the next window
        if p["phase"] == "search":
            p["polls"] += 1
            if p["pause"] and p["polls"] <= 3:
                return "pending:" + p["pause"]
            if p["polls"] <= 4:
                return "pending:"
            p["phase"] = "found"
            return f"pending:Found {p['newName']} — pairing..."
        if p["phase"] == "found":
            p["phase"] = "confirm"
            return f"confirm:{PAIR_CODE}"
        if p["phase"] == "confirm":
            if p["decision"] is None:
                return f"confirm:{PAIR_CODE}"      # park until ConfirmPairing answers
            if not p["decision"]:
                # Like the daemon: a re-paired watch was forgotten up front and stays forgotten.
                self.pairing = {"phase": "result", "result": "error:Pairing declined"}
                return self.pairing["result"]
            p["phase"] = "done"
            return "pending:Completing pairing…"
        # phase == "done": register + connect the watch.
        name = p["newName"]
        self.watches[name] = p["restore"] or {
            "state": "disconnected", "battery": "", "transport": "ble",
            "model": "Pebble 2 HR", "platform": "DIORITE", "firmware": "4.4.2",
            "serial": "Q40NEW00000", "code": "NEW1", "lastSync": "just now",
        }
        self._set_connected(name)
        self.pairing = {"phase": "result", "result": "ok:Paired and connected"}
        return self.pairing["result"]

    @dbus.service.method(IFACE, in_signature="b", out_signature="s")
    def ConfirmPairing(self, accept):
        # Answer a confirm:<code> from PairStatus (numeric comparison).
        if self.pairing is None or self.pairing.get("phase") != "confirm" or self.pairing["decision"] is not None:
            return "error:No pairing confirmation pending"
        self.pairing["decision"] = bool(accept)
        return "ok:accepted" if accept else "ok:declined"

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def Unpair(self, name):
        if name == "":
            self.watches.clear()
            return "ok:forgot all watches"
        match = self._resolve(name)
        if match is None:
            return f"notfound:no known watch matching '{name}'"
        self.watches.pop(match, None)
        return f"ok:forgot {match}"

    @dbus.service.method(IFACE, in_signature="ss", out_signature="s")
    def SetWatchNickname(self, query, nickname):
        # HOOK #9: rename a known watch (libpebble3 KnownPebbleDevice.setNickname()).
        match = self._resolve(query)
        if match is None:
            return f"notfound:no known watch matching '{query}'"
        nickname = nickname.strip()
        if not nickname:
            return "error:nickname must not be empty"
        if nickname != match:
            self.watches[nickname] = self.watches.pop(match)
        return f"ok:renamed to {nickname}"

    # --- FindWatch / WatchInfoText ----------------------------------------
    @dbus.service.method(IFACE, in_signature="", out_signature="b")
    def FindWatch(self):
        return self._connected_name() is not None

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def WatchInfoText(self):
        name = self._connected_name()
        if name is None:
            return "notready:"
        w = self.watches[name]
        text = (
            f"Name:        {name}\n"
            f"Model:       {w['model']}\n"
            f"Firmware:    {w['firmware']}\n"
            f"Platform:    {w['platform']}\n"
            f"Serial:      {w['serial']}\n"
            f"Battery:     {w['battery'] or '?'}%\n"
            f"Capabilities: appglance, health, timeline, weather"
        )
        return f"ok:{text}"

    # --- Apps & Faces ------------------------------------------------------
    def _resolve_app(self, query):
        for a in self.apps:
            if a["uuid"] == query:
                return a
        hits = [a for a in self.apps if query.lower() in a["title"].lower()]
        return hits[0] if len(hits) == 1 else (None if not hits else "ambiguous")

    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def ListApps(self):
        return [rec(a["uuid"], a["type"], a["order"], ",".join(a["flags"]),
                    a["title"], a["developer"], a.get("version", "")) for a in self.apps]

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def GetAppIcon(self, uuid):
        # HOOK (app icons): the daemon extracts an installed app's menu icon from its cached .pbw and
        # writes it as a PNG, returning ok:<abs path> | none: | notready: | error:. We mirror that by
        # writing a tiny sample PNG per app to a temp dir so the GUI's per-row Image path is exercised
        # headlessly. A couple of UUIDs return none: to exercise the generic-fallback branch.
        app = self._resolve_app(uuid)
        if app is None or app == "ambiguous":
            return "none:"
        # Exercise the no-icon fallback for a subset (system apps + Isotime).
        if "system" in app["flags"] or app["uuid"] == "3af56a2b":
            return "none:"
        path = self._sample_icon_png(app["uuid"])
        if path is None:
            return "error:could not write sample icon"
        return f"ok:{path}"

    def _sample_icon_png(self, uuid):
        # A 25x25 RGBA PNG: a filled rounded-ish square tinted from the uuid, on transparent ground —
        # stands in for a real extracted menu icon. Pure stdlib (zlib), no Pillow dependency.
        import os
        import struct
        import zlib
        import tempfile
        d = os.path.join(tempfile.gettempdir(), "stoandl-mock-icons")
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, f"{uuid}.png")
        if os.path.exists(path):
            return path
        w = h = 25
        # Tint from the uuid hash so different apps look different.
        hv = sum(ord(c) for c in uuid)
        r, g, b = (60 + hv % 180), (60 + (hv * 7) % 180), (60 + (hv * 13) % 180)
        raw = bytearray()
        for y in range(h):
            raw.append(0)  # filter: none
            for x in range(w):
                inside = 2 <= x < w - 2 and 2 <= y < h - 2
                if inside:
                    raw += bytes((r, g, b, 255))
                else:
                    raw += bytes((0, 0, 0, 0))

        def chunk(tag, data):
            c = struct.pack(">I", len(data)) + tag + data
            return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

        sig = b"\x89PNG\r\n\x1a\n"
        ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)  # colorType 6 = RGBA
        idat = zlib.compress(bytes(raw))
        try:
            with open(path, "wb") as f:
                f.write(sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b""))
        except OSError:
            return None
        return path

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def LaunchApp(self, query):
        app = self._resolve_app(query)
        if app is None:
            return f"notfound:no app matching '{query}'"
        if app == "ambiguous":
            return f"ambiguous:'{query}' matches several apps"
        if app["type"] == "watchface":
            for a in self.apps:
                if a["type"] == "watchface" and "active" in a["flags"]:
                    a["flags"].remove("active")
            if "active" not in app["flags"]:
                app["flags"].insert(0, "active")
        self.LockerChanged()   # active-face change is a locker change
        return f"ok:launched {app['title']}"

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def RemoveApp(self, query):
        app = self._resolve_app(query)
        if app is None:
            return f"notfound:no app matching '{query}'"
        if app == "ambiguous":
            return f"ambiguous:'{query}' matches several apps"
        if "system" in app["flags"]:
            return "error:system apps cannot be removed"
        self.apps.remove(app)
        self.LockerChanged()
        return f"ok:removed {app['title']}"

    # --- watch tasks (sideload, screenshot, logs, coredump): start, then TaskStatus/TaskChanged ---
    def _task_start(self, kind, running, work, delay_ms=900):
        # Like the daemon's WatchTasks: one per kind, `ok:started` now, the result after a delay.
        tasks = self.__dict__.setdefault("_tasks", {})
        if tasks.get(kind, "").startswith("running:"):
            return f"busy:a {kind} task is already running"
        tasks[kind] = "running:" + running
        self.TaskChanged(kind, tasks[kind])

        def _finish():
            try:
                result = work()
            except OSError as e:
                result = f"error:{e}"
            tasks[kind] = result
            self.TaskChanged(kind, result)
            return False
        GLib.timeout_add(delay_ms, _finish)
        return "ok:started"

    @staticmethod
    def _task_out(path, sub, prefix, ext):
        # Empty path: the daemon picks Pictures/Screenshots or Documents/stoandl; the mock a temp dir.
        if path:
            return path if path.startswith("/") else None
        d = os.path.join("/tmp", "stoandl-mock", sub)
        os.makedirs(d, exist_ok=True)
        return os.path.join(d, f"{prefix}-{time.strftime('%Y%m%d-%H%M%S')}{ext}")

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def TaskStatus(self, kind):
        if kind not in ("sideload", "screenshot", "logs", "coredump"):
            return f"error:unknown task '{kind}'"
        return self.__dict__.get("_tasks", {}).get(kind, "idle:")

    @dbus.service.signal(IFACE, signature="ss")
    def TaskChanged(self, kind, status):
        # A watch task started (running:<what>) or ended (its result) — what TaskStatus now returns.
        pass

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def SideloadApp(self, path):
        if not path.startswith("/"):
            return f"error:No such file: {path}"
        base = path.rsplit("/", 1)[-1]
        title = base[:-4] if base.endswith(".pbw") else base

        def work():
            self._sideload_seq += 1
            order = max((a["order"] for a in self.apps), default=-1) + 1
            self.apps.append({
                "uuid": f"side{self._sideload_seq:04d}", "type": "watchapp",
                "order": order, "flags": ["sideloaded"], "title": title, "developer": "Sideloaded",
            })
            self.LockerChanged()
            return f"ok:Sideloaded {base}"
        return self._task_start("sideload", f"Installing {base}", work, delay_ms=1500)

    @dbus.service.method(IFACE, in_signature="si", out_signature="s")
    def SetAppOrder(self, query, order):
        # Move an entry to `order`, swapping with whichever entry currently holds it (the GUI
        # hands us the neighbour's order for a one-slot move). Orders stay unique/contiguous.
        app = self._resolve_app(query)
        if app is None:
            return f"notfound:no app matching '{query}'"
        if app == "ambiguous":
            return f"ambiguous:'{query}' matches several apps"
        order = int(order)
        holder = next((a for a in self.apps if a["order"] == order and a is not app), None)
        if holder is not None:
            holder["order"] = app["order"]
        app["order"] = order
        self.LockerChanged()
        return f"ok:reordered {app['title']}"

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def RestoreSystemAppOrder(self):
        # Reset built-in entries to their declared order; sideloaded keep their relative spot after.
        default_index = {u: i for i, u in enumerate(self._default_order)}
        builtins = sorted((a for a in self.apps if a["uuid"] in default_index),
                          key=lambda a: default_index[a["uuid"]])
        extras = sorted((a for a in self.apps if a["uuid"] not in default_index),
                        key=lambda a: a["order"])
        for i, a in enumerate(builtins + extras):
            a["order"] = i
        self.LockerChanged()
        return "ok:restored default order"

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def OpenConfig(self, query):
        app = self._resolve_app(query)
        if app is None or app == "ambiguous":
            return ""  # no config / not resolvable
        if "config" not in app["flags"]:
            return ""  # app has no config page
        # The daemon serves the page itself and returns a loopback URL (nothing listens here).
        return f"http://127.0.0.1:9/{app['uuid']}/"

    # --- Extensions / plugins ----------------------------------------------
    def _resolve_ext(self, query):
        for e in self.exts:
            if e["name"] == query:
                return e
        hits = [e for e in self.exts if query.lower() in e["name"].lower()]
        return hits[0] if len(hits) == 1 else ("ambiguous" if hits else None)

    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def ExtList(self):
        # HOOK #7: `config` (none|schema) + `description` + `author` + `version` + the last stderr line.
        return [rec(e["name"],
                    "installed" if e["installed"] else "missing",
                    "enabled" if e["enabled"] else "disabled",
                    "running" if e["running"] else "stopped",
                    e["config"], e["description"],
                    e.get("author", ""), e.get("version", ""),
                    e.get("stderr", "") if e["running"] else "") for e in self.exts]

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def ExtEnable(self, query):
        e = self._resolve_ext(query)
        if e is None or e == "ambiguous":
            return f"notfound:no extension matching '{query}'"
        e["enabled"] = True
        e["running"] = e["installed"]
        self.ExtensionsChanged()
        if e["running"]:
            self.ExtensionStateChanged(e["name"], "ready")
        return f"ok:enabled {e['name']}"

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def ExtDisable(self, query):
        e = self._resolve_ext(query)
        if e is None or e == "ambiguous":
            return f"notfound:no extension matching '{query}'"
        e["enabled"] = False
        e["running"] = False
        self.ExtensionsChanged()
        return f"ok:disabled {e['name']}"

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def ExtRestart(self, query):
        e = self._resolve_ext(query)
        if e is None or e == "ambiguous":
            return f"notfound:no extension matching '{query}'"
        if not e["enabled"]:
            return f"error:{e['name']} is disabled"
        e["running"] = e["installed"]
        self.ExtensionsChanged()
        if e["running"]:
            self.ExtensionStateChanged(e["name"], "ready")
        return f"ok:restarted {e['name']}"

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def ExtCrash(self, query):
        # MOCK-ONLY trigger (not in the real daemon's contract): drive an UNSOLICITED crash
        # → quarantine sequence so the GUI's ExtensionStateChanged handling is exercisable.
        # Fires `exited` (process ended, restarting after backoff) now, then `quarantined`
        # (gave up after rapid failures) on a GLib tick. The polled ExtList keeps the ext in
        # `running` throughout — that's the whole point: only the signal reveals the quarantine.
        e = self._resolve_ext(query)
        if e is None or e == "ambiguous":
            return f"notfound:no extension matching '{query}'"
        if not (e["enabled"] and e["installed"]):
            return f"error:{e['name']} is not running"
        name = e["name"]
        e["stderr"] = "panic: mock crash (the homeserver didn't answer)"   # ExtList's lastStderr
        self.ExtensionStateChanged(name, "exited")

        def _quarantine():
            self.ExtensionStateChanged(name, "quarantined")
            return False  # one-shot

        GLib.timeout_add(800, _quarantine)
        return f"ok:crashing {name}"

    @dbus.service.method(IFACE, in_signature="sb", out_signature="s")
    def ExtUninstall(self, query, keep_config):
        e = self._resolve_ext(query)
        if e is None or e == "ambiguous":
            return f"notfound:no extension matching '{query}'"
        self.exts.remove(e)
        kept = " (config kept)" if keep_config else ""
        self.ExtensionsChanged()
        return f"ok:uninstalled {e['name']}{kept}"

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def ExtInstall(self, path):
        if not path:
            return "error:empty path"
        base = path.rsplit("/", 1)[-1]
        for suffix in (".tar.gz", ".tgz", ".tar", ".zip"):
            if base.endswith(suffix):
                base = base[: -len(suffix)]
                break
        self._ext_seq += 1
        self.exts.append({"name": base, "installed": True, "enabled": True, "running": True,
                          "config": "none", "description": "Sideloaded extension"})
        self.ExtensionsChanged()
        return f"ok:installed {base}"

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def ExtConfigSchema(self, query):
        # HOOK #7 (schema backend): typed manifest as JSON.
        e = self._resolve_ext(query)
        if e is None or e == "ambiguous":
            return f"notfound:no extension matching '{query}'"
        schema = self.ext_schema.get(e["name"])
        if not schema:
            return "none:"
        return "ok:" + json.dumps(schema)

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def ExtGetConfig(self, query):
        e = self._resolve_ext(query)
        if e is None or e == "ambiguous":
            return f"notfound:no extension matching '{query}'"
        return "ok:" + json.dumps(self.ext_values.get(e["name"], {}))

    @dbus.service.method(IFACE, in_signature="ss", out_signature="s")
    def ExtSetConfig(self, query, payload):
        e = self._resolve_ext(query)
        if e is None or e == "ambiguous":
            return f"notfound:no extension matching '{query}'"
        try:
            values = json.loads(payload)
        except ValueError as exc:
            return f"error:bad json: {exc}"
        self.ext_values.setdefault(e["name"], {}).update(values)
        return f"ok:saved {e['name']} settings"

    # --- Sync (force-sync + HOOK #5 master toggles / status) ---------------
    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def SyncWeather(self):
        if not self._sync_on("weather"):
            return "error:weather is not enabled in config"
        self.sync["weather"]["lastSync"] = "just now"
        return "ok:weather pushed"

    # Canned geocoder answers; the daemon asks Open-Meteo (gated like here).
    MOCK_PLACES = [("Berlin", 52.5244, 13.4105, "Land Berlin", "Germany"),
                   ("Berlin", 39.9209, -74.9407, "New Jersey", "United States")]

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def SearchWeatherPlace(self, query):
        if not self._sync_on("weather"):
            return "disabled:Weather sync is off (weather.enabled)"
        if self.config.get("weather.place_search") != "true":
            return "disabled:Place search is off: it sends the name to Open-Meteo's geocoder. Turn on weather.place_search"
        q = str(query).strip()
        if not q:
            return "error:Type a place name to search for"
        hits = [p for p in self.MOCK_PLACES if q.lower() in p[0].lower()]
        if not hits:
            return "none:No place called \"" + q + "\" found (or Open-Meteo couldn't be reached)"
        return "ok:" + "\n".join(rec(*p) for p in hits)

    @dbus.service.method(IFACE, in_signature="sdd", out_signature="s")
    def AddWeatherLocation(self, name, lat, lon):
        label = " ".join(str(name).replace(",", " ").replace("#", " ").split())
        if not label:
            return "error:The location needs a name"
        entries = [e for e in self.config.get("weather.locations", "").split(",") if e.strip()]
        kept = [e for e in entries if e.rpartition(":")[0].rpartition(":")[0].lower() != label.lower()]
        verb = "Updated" if len(kept) < len(entries) else "Added"
        self.config["weather.locations"] = ",".join(kept + [f"{label}:{float(lat)!r}:{float(lon)!r}"])
        return f"ok:{verb} {label} ({lat}, {lon})"

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def SyncCalendar(self):
        if not self._sync_on("calendar"):
            return "error:calendar is not enabled in config"
        self.sync["calendar"]["lastSync"] = "just now"
        return "ok:calendar pins updated"

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def SyncHealth(self):
        if not self._sync_on("health"):
            return "error:health is not enabled in config"
        self.sync["health"]["lastSync"] = "just now"
        self.health["lastSync"] = "just now"
        return "ok:health data refreshed"

    def _sync_on(self, service):
        value = self.config.get(SYNC_SERVICE_KEYS[service], "")
        return value not in ("false", "Off", "")

    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def GetSyncStatus(self):
        # HOOK #5: service\tenabled\tavailable\tlastSync\tkey.
        def last(s, v):
            if s == "dnd":
                return CONFIG_COMBO_TOKENS["dnd.sync"].get(self.config["dnd.sync"], "off")
            return v["lastSync"] if self._sync_on(s) else "off"
        return [rec(s, "enabled" if self._sync_on(s) else "disabled",
                    "available" if v["available"] else "unavailable", last(s, v), SYNC_SERVICE_KEYS[s])
                for s, v in self.sync.items()]

    @dbus.service.method(IFACE, in_signature="sb", out_signature="s")
    def SetSyncEnabled(self, service, enabled):
        # HOOK #5: an alias for SetConfig of the service's key; dnd's key is four-way.
        if service not in SYNC_SERVICE_KEYS:
            return f"notfound:no sync service '{service}'"
        if service == "dnd":
            return "error:use dnd.sync (off|to_watch|to_host|both)"
        r = self.SetConfig(SYNC_SERVICE_KEYS[service], "true" if enabled else "false")
        return f"ok:{service} {'enabled' if enabled else 'disabled'}" if r.startswith("ok:") else r

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def MusicStatus(self):
        # Live now-playing for the Music sync row: ok:<playing|paused>\t<player>\t<track>.
        # No active player → idle: (the row falls back to its "Last sync · …" subtitle).
        m = self._music
        if not m.get("player"):
            return "idle:"
        state = "playing" if m["playing"] else "paused"
        return "ok:" + rec(state, m["player"], m["track"])

    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def ListCalendars(self):
        return [rec(c["id"], c["name"], "enabled" if c["enabled"] else "disabled", c.get("accountId", ""))
                for c in self.calendars]

    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def ListCalendarSources(self):
        # id \t type \t url \t username \t label \t lastError \t lastSync (epoch s; password is write-only)
        return [rec(s["id"], s["type"], s["url"], s.get("username", ""), s.get("label", ""),
                    s.get("lastError", ""), str(s["lastSync"]) if s.get("lastSync") else "")
                for s in self.calendar_sources]

    @dbus.service.method(IFACE, in_signature="ssss", out_signature="s")
    def AddCalendarSource(self, type, url, username, password):
        url = url.strip()
        if not url:
            return "error:a URL or path is required"
        if type == "caldav":
            token = "ab12cd%02d" % self._caldav_next
            self._caldav_next += 1
            sid = "caldav:" + token
            label = url.split("//")[-1].split("/")[0]
            backend = ("keyring" if password else "none")
        elif type == "ical":
            sid = "ical:" + url
            label = url.split("//")[-1].split("/")[0]
            backend = "none"
        elif type == "ics":
            sid = "ics:" + url
            label = url.rstrip("/").split("/")[-1] or url
            backend = "none"
        else:
            return f"error:unknown source type '{type}'"
        if any(s["id"] == sid for s in self.calendar_sources):
            return "error:that source is already configured"
        self.calendar_sources.append(
            {"id": sid, "type": type, "url": url, "username": username, "label": label})
        return f"ok:{sid}\t{backend}"

    @dbus.service.method(IFACE, in_signature="ssss", out_signature="s")
    def UpdateCalendarSource(self, id, url, username, password):
        src = next((s for s in self.calendar_sources if s["id"] == id), None)
        if src is None:
            return f"notfound:no source '{id}'"
        if url.strip():
            src["url"] = url.strip()
        src["username"] = username
        backend = ("keyring" if password else "kept") if src["type"] == "caldav" else "none"
        return f"ok:{id}\t{backend}"

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def RemoveCalendarSource(self, id):
        before = len(self.calendar_sources)
        self.calendar_sources = [s for s in self.calendar_sources if s["id"] != id]
        if len(self.calendar_sources) == before:
            return f"notfound:no source '{id}'"
        # Drop the calendars that belonged to it (so the GUI's group disappears).
        self.calendars = [c for c in self.calendars if c.get("accountId") != id]
        return "ok:removed"

    @dbus.service.method(IFACE, in_signature="sb", out_signature="s")
    def SetCalendarEnabled(self, query, enabled):
        cal = None
        for c in self.calendars:
            if c["id"] == query:
                cal = c
                break
        if cal is None:
            hits = [c for c in self.calendars if query.lower() in c["name"].lower()]
            cal = hits[0] if len(hits) == 1 else None
        if cal is None:
            return f"notfound:no calendar matching '{query}'"
        cal["enabled"] = bool(enabled)
        return f"ok:{cal['name']} {'enabled' if enabled else 'disabled'}"

    # --- Watch settings (ListWatchPrefs / SetWatchPref) --------------------
    def _watch_pref_text(self, p):
        return WATCH_PREF_TEXT.get(p["id"], ("Other", "", ""))

    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def ListWatchPrefs(self):
        # 11 columns; grouped by section in display order, like the daemon.
        rows = sorted(self.prefs, key=lambda p: WATCH_PREF_SECTIONS.index(self._watch_pref_text(p)[0]))
        return [rec(p["id"], p["type"], p["current"], p["default"], p["allowed"],
                    p["flags"], p["name"], p["description"], *self._watch_pref_text(p)) for p in rows]

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def ResetWatchPrefs(self):
        changed = [p for p in self.prefs if p["current"] != p["default"]]
        for p in changed:
            p["current"] = p["default"]
        return f"ok:Reset {len(changed)} watch settings to their defaults (syncs to the watch on next connect)"

    # Backlight color presets — name → 0xRRGGBB — matching libpebble3's BACKLIGHT_COLOR_PRESETS
    # (WatchPrefEntity.kt). The daemon's parseColor() resolves a preset NAME first, then a hex.
    COLOR_PRESETS = {
        "red": "0xFF0000", "orange": "0xFF7F00", "yellow": "0xFFFF00", "lime": "0x7FFF00",
        "green": "0x00FF00", "cyan": "0x00FFFF", "blue": "0x0000FF", "purple": "0x7F00FF",
        "magenta": "0xFF00FF", "pink": "0xFF66CC", "warm white": "0xFFBFA2", "cool white": "0xFFFFFF",
    }

    @staticmethod
    def _parse_schedule(raw):
        """libpebble3's QuietTimeSchedule.parse(): exactly one '-' between two H:MM/HH:MM times,
        hours 0-23, minutes 0-59 (each side may carry spaces). Returns the zero-padded
        "HH:MM-HH:MM" the daemon stores and lists back, or None."""
        times = raw.split("-")
        if len(times) != 2:
            return None
        out = []
        for t in times:
            parts = t.strip().split(":")
            if len(parts) != 2 or not all(re.fullmatch(r"\+?\d+", x) for x in parts):
                return None
            h, m = int(parts[0]), int(parts[1])
            if not (0 <= h <= 23 and 0 <= m <= 59):
                return None
            out.append(f"{h:02d}:{m:02d}")
        return "-".join(out)

    @dbus.service.method(IFACE, in_signature="ss", out_signature="s")
    def SetWatchPref(self, pref_id, value):
        # Mirrors WatchPrefsControl.setOne(): parse per type (same error texts), store what the
        # daemon's format() would list back, and answer "ok:Set <id> = <value> (…)".
        p = next((x for x in self.prefs if x["id"] == pref_id), None)
        if p is None:
            return f"error:Unknown watch pref '{pref_id}' (see 'stoandl settings')"
        raw, t = value, value.strip()
        if p["type"] == "bool":
            if t.lower() in ("1", "true", "yes", "on"):
                cur = "true"
            elif t.lower() in ("0", "false", "no", "off"):
                cur = "false"
            else:
                return f"error:'{raw}' is not a boolean (use true/false)"
        elif p["type"] == "number":
            lo, _, hi = p["allowed"].split(" ", 1)[0].partition("..")
            unit = p["allowed"].split(" ", 1)[1] if " " in p["allowed"] else ""
            suffix = f" {unit}" if unit else ""
            if not re.fullmatch(r"[+-]?\d+", t):
                return f"error:'{raw}' is not a number for {pref_id}"
            n = int(t)
            if n < int(lo) or n > int(hi):
                return f"error:{pref_id} must be {lo}..{hi}{suffix} (got {n})"
            cur = f"{n}{suffix}"
        elif p["type"] == "enum":
            opts = p["allowed"].split("|")
            cur = next((o for o in opts if o.lower() == t.lower()), None)
            if cur is None:
                return f"error:'{raw}' is not valid for {pref_id}; allowed: {', '.join(opts)}"
        elif p["type"] == "color":
            # A preset NAME (or a hex) resolves to 0xRRGGBB, like parseColor().
            cur = self.COLOR_PRESETS.get(t.lower())
            if cur is None:
                hexv = t.removeprefix("#").removeprefix("0x").removeprefix("0X")
                if not re.fullmatch(r"[0-9A-Fa-f]+", hexv):
                    return f"error:'{raw}' is not a color (hex RRGGBB or a preset name) for {pref_id}"
                cur = "0x" + hexv[-6:].upper().rjust(6, "0")
        elif p["type"] == "quicklaunch":
            action = next((a for a in QL_ALLOWED.split("|")[1:-1]
                           if re.sub(r"[\s_-]", "", a).lower() == re.sub(r"[\s_-]", "", t).lower()), None)
            cur = "off" if t.lower() in ("", "off", "none", "disabled") else (action or t)
        elif p["type"] == "schedule":
            cur = self._parse_schedule(raw)
            if cur is None:
                return f"error:'{raw}' is not a time window (HH:MM-HH:MM, 24 h) for {pref_id}"
        else:
            cur = t
        p["current"] = cur
        return f"ok:Set {pref_id} = {cur} (syncs to the watch on next connect)"

    # --- Notifications -----------------------------------------------------
    def _resolve_notif(self, query):
        for a in self.notif_apps:
            if a["name"].lower() == query.lower():
                return a
        hits = [a for a in self.notif_apps if query.lower() in a["name"].lower()]
        return hits[0] if len(hits) == 1 else None

    @staticmethod
    def _mute_label(a):
        # The daemon's muteLabel: never/always/weekdays/weekends, or `muted-until <instant>` (Kotlin's
        # Instant.toString, UTC) while a temporary mute runs; an expired one reads never.
        until = a.get("until", 0)
        if until:
            if until <= time.time():
                return "never"
            return "muted-until " + datetime.datetime.fromtimestamp(until, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        return a["mute"]

    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def NotifList(self):
        return [rec(a["name"], self._mute_label(a), a["color"], a["icon"], a["vibe"], a["last"], a["app_name"],
                    "off" if a.get("images_off") else "")
                for a in self.notif_apps]

    @dbus.service.method(IFACE, in_signature="ss", out_signature="s")
    def NotifSetMute(self, query, spec):
        # The daemon's parseSpec: always/on/mute, never/off/unmute, weekdays, weekends, or a duration
        # (a temporary always). There is no `today` for one app.
        a = self._resolve_notif(query)
        if a is None:
            return f"notfound:no app matching '{query}'"
        s = (spec or "").strip().lower()
        states = {"": "always", "always": "always", "on": "always", "mute": "always", "never": "never",
                  "off": "never", "unmute": "never", "weekdays": "weekdays", "weekends": "weekends"}
        if s in states:
            a["mute"], a["until"] = states[s], 0
            return f"ok:{'Unmuted ' + a['name'] if a['mute'] == 'never' else 'Muted ' + a['name']}" + \
                (f" on {a['mute']}" if a["mute"] in ("weekdays", "weekends") else "")
        m = re.fullmatch(r"(\d+)\s*([smhd])", s)
        if not m:
            return f"error:Unknown mute '{spec}' (use always, never, weekdays, weekends or a time like 30m)"
        a["mute"], a["until"] = "always", time.time() + int(m.group(1)) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]
        return f"ok:Muted {a['name']} until {self._mute_label(a)[12:]} (temporary)"

    @dbus.service.method(IFACE, in_signature="ss", out_signature="s")
    def NotifSetImages(self, query, mode):
        a = self._resolve_notif(query)
        if a is None:
            return f"notfound:no app matching '{query}'"
        m = mode.strip().lower()
        if m not in ("on", "off", "default", ""):
            return f"error:Unknown images mode '{mode}' (use on, off or default)"
        a["images_off"] = m == "off"
        return f"ok:{a['name']} images {'off' if a['images_off'] else 'follow notification.images'}"

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def NotifSetMuteAll(self, spec):
        # One temporary mute over every app, apart from the per-app mutes (as in the daemon's GlobalMute).
        s = (spec or "").strip().lower()
        if s in ("never", "off", "unmute", "resume", ""):
            was = self.__dict__.get("muted_until", 0) > time.time()
            self.muted_until = 0
            return "ok:Notifications resumed" if was else "ok:Notifications weren't muted"
        if s in ("always", "on", "mute", "weekdays", "weekends"):
            return ("error:Muting all apps is temporary: give a time (30m, 1h, 2d or today). To stop "
                    "forwarding until you turn it back on, set notification.forward to false")
        if s == "today":
            now = datetime.datetime.now()
            end = (now + datetime.timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
            self.muted_until = end.timestamp()
        else:
            m = re.fullmatch(r"(\d+)\s*([smhd])", s)
            if not m:
                return f"error:Unknown mute '{spec}' (use a time like 30m, 1h, 2d, or today, or never to resume)"
            secs = int(m.group(1)) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]
            self.muted_until = time.time() + secs
        return "ok:Muted all notifications until " + time.strftime("%H:%M", time.localtime(self.muted_until))

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def NotifMuteAllStatus(self):
        until = self.__dict__.get("muted_until", 0)
        return f"muted:{int(until)}" if until > time.time() else "none:"

    @dbus.service.method(IFACE, in_signature="ssss", out_signature="s")
    def NotifSetStyle(self, query, color, icon, vibe):
        a = self._resolve_notif(query)
        if a is None:
            return f"notfound:no app matching '{query}'"
        for field, val in (("color", color), ("icon", icon), ("vibe", vibe)):
            if val == "":
                continue
            a[field] = "default" if val == "default" else val
        return f"ok:{a['name']} style updated"

    # NotifStyleChoices: the built-in vibrations (VibePatterns, in the daemon's order) and the curated icons.
    MOCK_VIBES = [("Standard", "300,300"), ("Pulses", "100,100,100,100"), ("Double", "200,100,200"),
                  ("Triple", "200,100,200,100,200"), ("Subtle", "100"), ("Long", "800")]
    MOCK_ICONS = [("calendar", "Calendar"), ("mail", "Mail"), ("chat", "Chat"), ("phone", "Phone")]

    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def NotifStyleChoices(self):
        custom = self.__dict__.setdefault("custom_vibes", {})
        return ([rec("vibe", name, name, ms, "builtin") for name, ms in self.MOCK_VIBES]
                + [rec("vibe", name, name, ms, "custom") for name, ms in custom.items()]
                + [rec("icon", value, label) for value, label in self.MOCK_ICONS])

    @staticmethod
    def _vibe_pattern_err(pattern):
        # The daemon's limits: on/off ms, at most 64 segments and 10 s in total.
        try:
            ms = [int(x) for x in pattern.split(",")]
        except ValueError:
            return "expected on/off milliseconds separated by commas, e.g. 200,100,200"
        if not ms or any(x <= 0 for x in ms):
            return "every segment must be a positive number of milliseconds"
        if len(ms) > 64 or sum(ms) > 10000:
            return "at most 64 segments and 10 seconds in total"
        return None

    @dbus.service.method(IFACE, in_signature="ss", out_signature="s")
    def NotifSetVibePattern(self, name, pattern):
        # Add, replace or (empty pattern) remove a custom vibration; built-ins, CSVs and reset words are refused.
        n, p = name.strip(), pattern.strip().replace(" ", "")
        custom = self.__dict__.setdefault("custom_vibes", {})
        if not n or n.lower() in ("default", "none", "clear") or any(n.lower() == b.lower() for b, _ in self.MOCK_VIBES) \
                or re.fullmatch(r"[\d,\s]+", n):
            return f"error:'{name}' can't name a custom vibration (a built-in, a pattern or a reset word)"
        if not p:
            if n not in custom:
                return f"notfound:no custom vibration '{n}'"
            del custom[n]
            return f"ok:Removed vibration {n}"
        err = self._vibe_pattern_err(p)
        if err:
            return f"error:{err}"
        verb = "Replaced" if n in custom else "Added"
        custom[n] = p
        return f"ok:{verb} vibration {n} ({p} ms)"

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def NotifVibeTest(self, spec):
        # Buzz the connected watch with a name, a CSV or `default`, outside the notification pipeline.
        if self._connected_name() is None:
            return "notready:No watch connected"
        s = spec.strip()
        names = {b.lower(): b for b, _ in self.MOCK_VIBES}
        names.update({c.lower(): c for c in self.__dict__.get("custom_vibes", {})})
        if s.lower() == "default" or s.lower() in names:
            return f"ok:Buzzed {names.get(s.lower(), 'the watch default')}"
        err = self._vibe_pattern_err(s)
        return f"error:Unknown vibration '{spec}'" if err else f"ok:Buzzed {s} ms"

    @dbus.service.method(IFACE, in_signature="ss", out_signature="s")
    def NotifSetAppName(self, query, placement):
        # Per-app override of notification.app_name; default/''/none/clear drops it (follows the global).
        p = placement.strip().lower()
        if p in ("", "default", "none", "clear"):
            p = ""
        elif p not in ("small", "subtitle", "off"):
            return f"error:Unknown app-name placement '{placement}' (use small|subtitle|off|default)"
        a = self._resolve_notif(query)
        if a is None:
            return f"notfound:no app matching '{query}'"
        a["app_name"] = p
        return f"ok:{a['name']} app name = {p or 'default (follows notification.app_name)'}"

    @dbus.service.method(IFACE, in_signature="ss", out_signature="s")
    def SendTestNotification(self, title, body):
        # Push a synthetic notification through the normal mute/style/filter path.
        if self._connected_name() is None:
            return "notready:no watch connected"
        if not title:
            return "error:title is required"
        return "ok:sent"

    # HOOK (notifications): regex filters (config-backed).
    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def NotifListFilters(self):
        return [rec(f["pattern"], f["action"]) for f in self.filters]

    @dbus.service.method(IFACE, in_signature="ss", out_signature="s")
    def NotifAddFilter(self, pattern, action):
        if not pattern:
            return "error:empty pattern"
        action = action if action in ("allow", "block") else "block"
        self.filters.append({"pattern": pattern, "action": action})
        return f"ok:added {action} filter"

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def NotifRemoveFilter(self, pattern):
        before = len(self.filters)
        self.filters = [f for f in self.filters if f["pattern"] != pattern]
        if len(self.filters) == before:
            return f"notfound:no filter matching '{pattern}'"
        return "ok:filter removed"

    # --- Health (HOOK #8) --------------------------------------------------
    # Per-day data is generated deterministically from each date's ordinal so day/week/month all work.
    # A day is "absent" (no data at all) on ~1/11 ordinals — exercises gaps + the empty states.
    def _present(self, d):
        return (d.toordinal() % 11) != 4

    def _steps_for(self, d):
        if not self._present(d):
            return None
        return 4200 + (d.toordinal() * 137) % 6000          # 4200..10199

    def _typical_steps_for(self, d):
        return 6200 + d.weekday() * 240                       # a per-weekday typical daily total

    def _sleep_for(self, d):
        """(totalMin, deepMin) for the night ending on d, or None."""
        if not self._present(d):
            return None
        o = d.toordinal()
        total = 360 + (o * 53) % 200                          # 6h00 .. 9h20
        deep = int(total * (0.22 + (o % 5) * 0.02))
        return (total, deep)

    def _sleep_clock(self, d):
        """(bedtime, wakeup) epoch seconds for the night ending the morning of d."""
        midnight = int(datetime.datetime(d.year, d.month, d.day).timestamp())
        o = d.toordinal()
        bed = midnight - (20 + o % 90) * 60                   # ~23:20–23:50 the night before
        wake = midnight + (6 * 3600) + (40 + o % 80) * 60     # ~06:40–08:00
        return (bed, wake)

    def _sleep_timeline(self, d):
        """Light/deep segments (startFraction, widthFraction, isDeep) over a 6 PM→noon window."""
        s = self._sleep_for(d)
        if s is None:
            return []
        o = d.toordinal()
        start = 0.28 + (o % 7) * 0.01
        width = 0.38 + (s[0] - 360) / 200.0 * 0.12
        deeps = [(start + 0.06 + i * 0.11, 0.025 + (o + i) % 3 * 0.006, 1) for i in range(4)]
        return [(round(start, 4), round(width, 4), 0)] + [(round(a, 4), round(b, 4), c) for a, b, c in deeps]

    def _hr_samples(self, d):
        """Deterministic minute-level (minuteOfDay, bpm) for day d, mirroring the daemon's per-minute
        getHealthDataForRange. Absent days -> []; ~1/13 ordinals are SPARSE (every 15 min)."""
        if not self._present(d):
            return []
        o = d.toordinal()
        sparse = (o % 13) == 2
        base = 56 + (o % 3) * 3
        samples = []
        for minute in range(0, 1440):
            hour = minute / 60.0
            awake = 6.5 <= hour <= 23.0
            take = True if awake else (minute % 12 == 0)
            if sparse and minute % 15 != 0:
                take = False
            if not take:
                continue
            circadian = base + 20 * max(0.0, math.sin((hour - 6.0) / 18.0 * math.pi))
            noise = ((minute * 2654435761 + o * 40503) % 13) - 6
            spike = 35 if (abs(hour - 8.2) < 0.25 or abs(hour - 18.5) < 0.30) else 0
            bpm = int(round(circadian + noise + spike))
            samples.append((minute, max(45, min(165, bpm))))
        return samples

    def _hr_avg_for(self, d):
        s = self._hr_samples(d)
        return None if not s else round(sum(b for _, b in s) / len(s))

    # 24 hourly step buckets for day d (deterministic; sums ≈ the day's total) — the daily steps graph.
    _STEP_HOURS = [0, 0, 0, 0, 0, 0, 2, 5, 8, 4, 3, 4, 6, 4, 3, 4, 7, 8, 6, 4, 3, 2, 1, 0]
    def _hourly_steps(self, d):
        total = self._steps_for(d)
        if total is None:
            return [0] * 24
        sw = sum(self._STEP_HOURS)
        return [int(total * w / sw) for w in self._STEP_HOURS]

    def _window(self, period_type, offset):
        """(days, labels) for a (periodType, offset) selection — mirrors the daemon's healthWindow."""
        today = datetime.date.today()
        off = max(0, int(offset))
        if period_type == "week":
            end = today - datetime.timedelta(days=off * 7)
            start = end - datetime.timedelta(days=6)
            days = [start + datetime.timedelta(days=i) for i in range(7)]
            return days, [d.strftime("%a %-d") for d in days]
        if period_type == "month":
            y, m = today.year, today.month - off
            while m <= 0:
                m += 12
                y -= 1
            start = datetime.date(y, m, 1)
            if off == 0:
                last = today
            elif m == 12:
                last = datetime.date(y, 12, 31)
            else:
                last = datetime.date(y, m + 1, 1) - datetime.timedelta(days=1)
            days, d = [], start
            while d <= last:
                days.append(d)
                d += datetime.timedelta(days=1)
            return days, [str(d.day) for d in days]
        # day
        d = today - datetime.timedelta(days=off)
        return [d], [d.strftime("%a %-d")]

    @dbus.service.method(IFACE, in_signature="si", out_signature="s")
    def GetHealthSummary(self, period_type, offset):
        h = self.health
        days, _ = self._window(period_type, offset)
        is_day = period_type not in ("week", "month")

        steps_vals = [s for s in (self._steps_for(d) for d in days) if s is not None]
        days_with_data = max(1, len(steps_vals))
        steps_total = sum(steps_vals)
        steps_avg = steps_total // days_with_data
        distance_km = "%.1f" % (steps_total / 1300.0 / days_with_data)
        kcal = steps_total // 25 // days_with_data
        active = sum(30 + d.toordinal() % 40 for d in days if self._present(d)) // days_with_data
        typicals = [self._typical_steps_for(d) for d in days]
        steps_typical = sum(typicals) // len(typicals) if typicals else 0

        nights = [n for n in (self._sleep_for(d) for d in days) if n is not None]
        if is_day:
            s = nights[0] if nights else None
            sleep_total = s[0] if s else 0
            sleep_deep = s[1] if s else 0
            bedtime, wakeup = self._sleep_clock(days[0]) if s else (0, 0)
        else:
            n = max(1, len(nights))
            sleep_total = sum(t for t, _ in nights) // n
            sleep_deep = sum(dp for _, dp in nights) // n
            bedtime = wakeup = 0
        sleep_light = max(0, sleep_total - sleep_deep)

        hr_avgs = [a for a in (self._hr_avg_for(d) for d in days) if a is not None]
        hr_avg = sum(hr_avgs) // len(hr_avgs) if hr_avgs else 0
        if is_day:
            bpms = [b for _, b in self._hr_samples(days[0])]
            hr_min = min(bpms) if bpms else 0
            hr_max = max(bpms) if bpms else 0
            hr_resting = (54 + days[0].toordinal() % 8) if bpms else 0
            hr_current = 72 if (offset == 0 and bpms) else 0
        else:
            hr_min = hr_max = hr_current = 0
            hr_resting = next((54 + d.toordinal() % 8 for d in reversed(days) if self._present(d)), 0)

        return "ok:" + rec(
            steps_total, steps_avg, steps_typical, distance_km, kcal, active,
            sleep_total, sleep_deep, sleep_light, h["sleepTypicalMin"], bedtime, wakeup,
            hr_avg, hr_resting, hr_current, hr_min, hr_max, h["hrAvailable"], days_with_data,
            h["lastSync"])

    @dbus.service.method(IFACE, in_signature="ssi", out_signature="as")
    def GetHealthSeries(self, metric, period_type, offset):
        days, labels = self._window(period_type, offset)
        is_day = period_type not in ("week", "month")
        if metric == "steps":
            if is_day:
                return [rec(h, v) for h, v in enumerate(self._hourly_steps(days[0]))]
            return [rec(labels[i], self._steps_for(d) if self._steps_for(d) is not None else "",
                        self._typical_steps_for(d)) for i, d in enumerate(days)]
        if metric == "sleep":
            if is_day:
                return [rec(s, w, deep) for (s, w, deep) in self._sleep_timeline(days[0])]
            rows = []
            for i, d in enumerate(days):
                n = self._sleep_for(d)
                rows.append(rec(labels[i], n[0] if n else 0, n[1] if n else 0))
            return rows
        if metric == "heart":
            if self.health["hrAvailable"] != "yes":
                return []
            if is_day:
                return [rec(m, bpm) for (m, bpm) in self._hr_samples(days[0])]
            return [rec(labels[i], self._hr_avg_for(d) if self._hr_avg_for(d) is not None else "")
                    for i, d in enumerate(days)]
        return []

    # --- Daemon config (HOOK #10) ------------------------------------------
    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def GetConfigSchema(self):
        return [rec(*(c[col] for col in CONFIG_COLS)) for c in self.config_schema]

    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def GetConfig(self):
        return [rec(k, v) for k, v in self.config.items()]

    @dbus.service.method(IFACE, in_signature="ss", out_signature="s")
    def SetConfig(self, key, value):
        # Mirrors the daemon's ConfigField.parse(): the GUI must handle a rejection with a reason, not
        # just a silent revert, so the mock rejects the same things the daemon does.
        field = next((c for c in self.config_schema if c["key"] == key), None)
        if field is None:
            return f"notfound:no config key '{key}'"
        v = str(value).strip()
        kind = field["type"]
        token = None  # what the daemon writes to stoandl.conf and echoes in its ok: reply
        if kind == "combo":
            # The label or the raw conf token (the label lower-cased with '_' for spaces, "To watch" <->
            # to_watch, unless CONFIG_COMBO_TOKENS says otherwise: "Small line" <-> small).
            opts = [o for o in field["options"].split(",") if o]
            tok = lambda o: CONFIG_COMBO_TOKENS.get(key, {}).get(o, o.lower().replace(" ", "_"))
            match = next((o for o in opts if v.lower() in (o.lower(), tok(o))), None)
            if match is None:
                return f"error:invalid value '{value}' for {key} (expected one of {field['options']})"
            v, token = match, tok(match)
        elif kind == "toggle":
            if v.lower() in ("true", "yes", "on", "1"):
                v = "true"
            elif v.lower() in ("false", "no", "off", "0"):
                v = "false"
            else:
                return f"error:invalid value '{value}' for {key} (expected true or false)"
        elif kind == "secret":
            # Kept out of stoandl.conf (the daemon's secret store); GetConfig shows only "set" or "".
            if "\n" in v or "\r" in v:
                return f"error:{key}: must be a single line"
            self.config[key] = "set" if v else ""
            self.ConfigChanged(key)
            return f"ok:{key} {'stored' if v else 'removed'}"
        elif kind == "int":
            try:
                n = int(v)
            except ValueError:
                return f"error:invalid value '{value}' for {key} (expected a whole number)"
            if field["min"] != "" and n < int(field["min"]):
                return f"error:{key} must be at least {field['min']}"
            if field["max"] != "" and n > int(field["max"]):
                return f"error:{key} must be at most {field['max']}"
            v = str(n)
        else:  # text | list — stoandl.conf is one `key = value` line with '#' starting a comment
            if "\n" in v or "\r" in v:
                return f"error:{key}: must be a single line"
            if "#" in v:
                return f"error:{key}: cannot contain '#' (it starts a comment in stoandl.conf)"
            if kind == "list":
                v = _list_encode(_list_decode(v))
            check = CONFIG_CHECKS.get(key)
            err, readback = check(v) if check else (None, v)
            if err:
                return f"error:{key}: {err}"
            token, v = v, readback   # e.g. weather.locations "Home:48:11" reads back as "Home:48.0:11.0"
        self.config[key] = v
        self.ConfigChanged(key)
        tail = " (restart stoandl to apply)" if field["apply"] == "restart" else ""
        return f"ok:{key} = {token if token is not None else v}{tail}"

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def Restart(self):
        # The daemon restarts its systemd unit a moment after replying; here the name drops and comes back.
        if self.pairing is not None and self.pairing.get("phase") != "result":
            return "busy:a pairing window is open"
        bus = self.connection
        GLib.timeout_add(300, lambda: bus.release_name(BUS_NAME) and False)
        GLib.timeout_add(1800, lambda: bus.request_name(BUS_NAME) and False)
        return "ok:restarting stoandl.service"

    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def GetHealthProfile(self):
        # The watch's own health-tracking config as key\tvalue records; hrm_interval adds the
        # intervals SetHealthProfile accepts right now as a third, |-joined field.
        def row(k, v):
            if k != "hrm_interval":
                return rec(k, v)
            allowed = [i for i in ("5min", "10min", "30min", "1h", "off") if self._interval_refusal(i) is None]
            return rec(k, v, "|".join(allowed))
        return [row(k, v) for k, v in self.health_profile.items()]

    def _interval_refusal(self, value):
        # The daemon's intervalRefusal(): switching to 5min needs a connected watch on 4.39.0+.
        if value != "5min" or self.health_profile["hrm_interval"] == "5min":
            return None
        name = self._connected_name()
        if name is None:
            return "Connect the watch first: 5min needs firmware 4.39.0 or newer"
        fw = self.watches[name]["firmware"]
        if tuple(int(p) for p in fw.lstrip("v").split("-")[0].split(".")[:3]) < (4, 39, 0):
            return f"{name} runs firmware {fw}; the 5-minute interval needs 4.39.0 or newer"
        return None

    @dbus.service.method(IFACE, in_signature="ss", out_signature="s")
    def SetHealthProfile(self, key, value):
        if key not in self.health_profile:
            return f"notfound:no health-profile key '{key}'"
        refusal = self._interval_refusal(value) if key == "hrm_interval" else None
        if refusal is not None:
            return f"error:{refusal}"
        self.health_profile[key] = value
        return f"ok:{key} = {value}"

    # --- Firmware ----------------------------------------------------------
    @dbus.service.method(IFACE, in_signature="", out_signature="s",
                         async_callbacks=("reply", "error"))
    def CheckFirmware(self, reply, error):
        self._check_firmware("CheckFirmware", reply)

    @dbus.service.method(IFACE, in_signature="", out_signature="s",
                         async_callbacks=("reply", "error"))
    def CheckFirmwareForce(self, reply, error):
        # The daemon's cache bypass (a GUI "check now"); the mock has no cache, so the same answer.
        self._check_firmware("CheckFirmwareForce", reply)

    def _check_firmware(self, method, reply):
        # HOOK: changelog URL appended as a 7th field for the "What's new" link.
        # ok:<board>\t<current>\t<latest>\t<asset>\t<yes|no>\t<source>\t<changelogUrl>
        result = rec("ok:snowy_s3", "4.4.2", "4.4.3", "core-fw.pbz", "yes", "github", CHANGELOG_URL)
        # MOCK_FW_CHECK_MS=<ms>: answer that late, as the daemon does while it downloads the GitHub
        # release list (8 s on a phone, uncached). The mock keeps serving other calls meanwhile, like
        # the daemon's worker pool, so the GUI must not wait for it.
        delay = int(os.environ.get("MOCK_FW_CHECK_MS", "0") or 0)
        self.fw_checks = getattr(self, "fw_checks", 0) + 1
        self.fw_cached_update = "4.4.3"  # what FirmwareStatus reports from the daemon's check cache
        print(f"mock: {method} #{self.fw_checks} (answers in {delay} ms)", flush=True)
        if delay <= 0:
            reply(result)
        else:
            GLib.timeout_add(delay, lambda: (reply(result), False)[1])

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def UpdateFirmware(self):
        if self.fw is not None and self.fw["prf_pending"]:
            return f"busy:A downgrade to {DOWNGRADE_VERSION} is pending: stoandl flashes it once the watch is in recovery"
        self._start_fw_push()   # walk + push FirmwareProgress on a GLib tick
        return rec("ok:snowy_s3", "4.4.2", "4.4.3", "core-fw.pbz")

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def SideloadFirmware(self, path):
        if not path:
            return "error:empty path"
        if self._reachable_name() is None:
            return "notready:No watch connected"
        # MOCK_FW_DOWNGRADE=1|drop: every sideload is an older .pbz on a dual-slot watch.
        self._start_fw_push(downgrade=os.environ.get("MOCK_FW_DOWNGRADE", ""))
        return f"ok:Flashing {path.rsplit('/', 1)[-1]}"

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def FirmwareStatus(self):
        # Non-advancing SNAPSHOT of the op the _fw_tick walker drives — the GLib walker owns
        # the step counter and pushes FirmwareProgress; this is just the polled fallback that
        # reports the current phase (so polling and the signal never double-advance the walk).
        # While idle, the daemon names newer firmware its check cache knows of (never a new check).
        if self.fw is None:
            cached = getattr(self, "fw_cached_update", None)
            return f"idle:available {cached}" if cached else "idle:"
        return self.fw["steps"][max(self.fw["step"], 0)][0]

    # --- Language packs ----------------------------------------------------
    def _resolve_lang(self, query):
        if not query:
            return self.languages[0]
        for L in self.languages:
            if query in (L["id"], L["iso"], L["name"]):
                return L
        hits = [L for L in self.languages if query.lower() in L["name"].lower()]
        return hits[0] if len(hits) == 1 else None

    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def ListLanguages(self):
        return [rec(L["id"], L["iso"], L["name"],
                    "yes" if L["installed"] else "no", L["source"]) for L in self.languages]

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def InstallLanguage(self, query):
        L = self._resolve_lang(query)
        if L is None:
            return f"notfound:no language matching '{query}'"
        self._start_lang_push(L["name"], L)
        return f"ok:{L['name']}"

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def SideloadLanguage(self, path):
        if not path:
            return "error:empty path"
        name = path.rsplit("/", 1)[-1]
        self._start_lang_push(name, None)
        return f"ok:installing {name}"

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def LanguageStatus(self):
        # Non-advancing SNAPSHOT of the op the _lang_tick walker drives — the GLib walker owns
        # the step counter and pushes LanguageProgress; this is just the polled fallback that
        # reports the current phase (so polling and the signal never double-advance the walk).
        if self.lang is None:
            return "idle:"
        p = self.lang["polls"]
        if p == 0:
            return f"downloading:{self.lang['name']}"
        if 1 <= p <= 4:
            return f"installing:{p * 25}"          # 25,50,75,100
        return f"done:{self.lang['name']}"

    # --- Developer connection ----------------------------------------------
    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def StartDevConnection(self):
        if self._connected_name() is None:
            return "notready:"
        self.dev_active = True
        return "ok:9000"

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def StopDevConnection(self):
        self.dev_active = False
        return "ok:stopped"

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def DevConnectionStatus(self):
        if self._connected_name() is None:
            return "notready:"
        return "ok:active" if self.dev_active else "ok:inactive"

    # --- Diagnostics -------------------------------------------------------
    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def TakeScreenshot(self, path):
        if self._reachable_name() is None:
            return "notready:No watch connected"
        out = self._task_out(path, "Screenshots", "pebble-screenshot", ".png")
        if out is None:
            return f"error:The path must be absolute: {path}"
        w, h = 144, 168   # a Pebble Time screen: a grey frame around white, like a blank watchface

        def work():
            with open(out, "wb") as f:
                f.write(_png_gray(w, h, lambda x, y: 255 if 8 <= x < w - 8 and 8 <= y < h - 8 else 96))
            return rec(f"ok:{out}", w, h)
        return self._task_start("screenshot", "Capturing the watch screen", work)

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def GatherLogs(self, path):
        if self._reachable_name() is None:
            return "notready:No watch connected"
        out = self._task_out(path, "Documents", "pebble-logs", ".txt")
        if out is None:
            return f"error:The path must be absolute: {path}"

        def work():
            with open(out, "w") as f:
                f.write("[mock] stoandl watch log\nbattery 72%\nfw 4.4.2\n")
            return f"ok:{out}"
        return self._task_start("logs", "Reading the watch's logs", work, delay_ms=2000)

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def GetCoreDump(self, path):
        if self._reachable_name() is None:
            return "notready:No watch connected"
        out = self._task_out(path, "Documents", "pebble-coredump", ".bin")
        if out is None:
            return f"error:The path must be absolute: {path}"

        def work():
            with open(out, "wb") as f:
                f.write(b"\x7fCORE[mock coredump]")
            return f"ok:{out}"
        return self._task_start("coredump", "Reading the watch's core dump", work)

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def Ping(self):
        # A PING round trip over the full protocol path: ok:<msg with latency> | notready: | error:.
        if self._connected_name() is None:
            return "notready:No watch connected"
        time.sleep(0.2)
        return "ok:Pong from the watch in 184 ms"

    # --- Reset -------------------------------------------------------------
    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def ResetIntoRecovery(self):
        return "ok:queued"

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def FactoryReset(self):
        return "ok:queued"

    # --- Version (soft) ----------------------------------------------------
    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def Version(self):
        return "mock-0.2.0"

    # --- Reactive signals --------------------------------------------------
    # The real daemon gained six signals on de.yoxcu.stoandl.Control. The GUI consumes
    # them as a push layer ON TOP of polling. We fire them from the same state mutations the
    # polled methods read, so a subscribed GUI updates without waiting for its next poll tick.
    @dbus.service.signal(IFACE, signature="")
    def WatchesChanged(self):
        # poke: re-call ListWatches. Fired on connect/disconnect/pair-completion.
        pass

    @dbus.service.signal(IFACE, signature="sis")
    def FirmwareProgress(self, phase, percent, detail):
        # phase ∈ {downloading,waiting,inprogress,reboot,failed,idle,notready};
        # percent 0–100 while inprogress else -1; detail = asset / failure reason.
        pass

    @dbus.service.signal(IFACE, signature="")
    def LockerChanged(self):
        # poke: re-call ListApps. Fired on sideload/remove/launch (active-face change).
        pass

    @dbus.service.signal(IFACE, signature="sis")
    def LanguageProgress(self, phase, percent, detail):
        # phase ∈ {downloading,installing,done,idle,failed,notready} (LanguageStatus vocabulary);
        # percent 0–100 while installing else -1; detail = language name / failure reason.
        pass

    @dbus.service.signal(IFACE, signature="")
    def PluginsChanged(self):
        # poke: re-call PluginList.
        pass

    @dbus.service.signal(IFACE, signature="")
    def PermissionRequestsChanged(self):
        # poke: re-call PermPending.
        pass

    @dbus.service.signal(IFACE, signature="s")
    def ConfigChanged(self, key):
        # A schema key was written (SetConfig, SetSyncEnabled, a model download): re-call GetConfig.
        pass

    # --- Plugins and app permissions ---------------------------------------
    MOCK_PLUGINS = [
        ("00000000-0000-0000-0001-000000000002", "builtin", "Weather", "Current conditions and forecast for the user's saved weather locations.", "weather/location,weather/hour", ""),
        ("00000000-0000-0000-0001-000000000003", "builtin", "Music", "What is playing on the phone, with play/pause and track skipping.", "music/track", "set_playing,next_track,previous_track"),
        ("2c4b7f10-9a3d-4e6b-8f21-5d0c7e9a1b34", "pbw", "Stocks", "Share prices for the tickers the user picked.", "finance/stock", ""),
    ]

    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def PluginList(self):
        return [rec(*p) for p in self.MOCK_PLUGINS]

    @dbus.service.method(IFACE, in_signature="sss", out_signature="s")
    def PluginRead(self, category, item, plugin):
        return 'ok:{"pluginUuid":"mock","instances":[]}'

    @dbus.service.method(IFACE, in_signature="sss", out_signature="s")
    def PluginInvoke(self, plugin, action, args):
        return "ok:Done"

    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def PermPending(self):
        # appUuid, appName, key, label, requestedAtMs, running, seen (PluginControl.pending)
        if not hasattr(self, "perm_pending"):
            self.perm_pending = [
                ["2c4b7f10-9a3d-4e6b-8f21-5d0c7e9a1b34", "Stocks", "Internet/query1.finance.yahoo.com", "Send data to query1.finance.yahoo.com", "1760000000000", "true", "false"],
                ["7e0d3a52-1b6c-4f8e-9a27-3c5d8e1f0b46", "Hue", "LocalNetwork", "Reach devices on the local network", "1760000100000", "false", "false"],
            ]
        return [rec(*r) for r in self.perm_pending]

    @dbus.service.method(IFACE, in_signature="s", out_signature="as")
    def PermList(self, app):
        # key, status (granted|denied|auto|waiting|blocked), kind, label, lastUsedMs
        self.PermPending()
        if not hasattr(self, "perm_decided"):
            self.perm_decided = {("2c4b7f10-9a3d-4e6b-8f21-5d0c7e9a1b34", "Location"): "granted"}
        rows = [(r[2], "waiting", "exfiltrating" if r[2].startswith("Internet") else "write", r[3], "0")
                for r in self.perm_pending if r[0] == app]
        rows += [(k, st, "read", "Your location", "1760000200000")
                 for (a, k), st in self.perm_decided.items() if a == app]
        rows.append(("Calendar", "auto", "read", "Your calendar", "0"))
        return [rec(*r) for r in sorted(rows)]

    @dbus.service.method(IFACE, in_signature="sss", out_signature="s")
    def PermSet(self, app, key, decision):
        self.PermPending(); self.PermList(app)
        if decision == "later":
            hit = [r for r in self.perm_pending if r[0] == app and (key == "" or r[2] == key)]
            if not hit:
                return f"notfound:nothing waiting"
            for r in hit:
                r[6] = "true"
        elif decision in ("allow", "deny"):
            self.perm_pending = [r for r in self.perm_pending if not (r[0] == app and r[2] == key)]
            self.perm_decided[(app, key)] = "granted" if decision == "allow" else "denied"
        elif decision == "reset":
            self.perm_decided.pop((app, key), None)
        self.PermissionRequestsChanged()
        return f"ok:{key or 'all'} {decision}"

    # --- Voice: the daemon's model store (VoiceModels.kt), speech models and voices alike, downloads ---
    # simulated over 6 s. Each entry: id, name, program, size MB, recommended, note, kind (stt|tts).
    MOCK_SPEECH_MODELS = [
        ("parakeet-v3", "Parakeet v3", "parakeet-cli", 669, "true", "25 European languages, detects the language; best accuracy for its speed (phones, older PCs)", "stt"),
        ("parakeet-v3-small", "Parakeet v3 (smaller)", "parakeet-cli", 356, "false", "the same model compressed further: less memory, slightly less accurate", "stt"),
        ("whisper-small", "Whisper small", "whisper-cli", 264, "false", "99 languages, set voice.language; slower and less accurate than Parakeet", "stt"),
        ("whisper-base", "Whisper base", "whisper-cli", 82, "false", "fast and small, weak for languages other than English", "stt"),
        ("whisper-turbo", "Whisper large-v3-turbo", "whisper-cli", 874, "false", "most accurate, for fast desktops only", "stt"),
        # The daemon's TTS catalog (voice/VoiceModels.kt), in its order.
        ("piper-de-thorsten-low", "Thorsten (German)", "piper", 63, "true", "German, male; low quality, fast: enough for the watch speaker. Thorsten-Voice dataset, CC0", "tts"),
        ("piper-en-kathleen-low", "Kathleen (English)", "piper", 63, "true", "US English, female; low quality, fast: enough for the watch speaker. Kathleen dataset, CC0", "tts"),
        ("piper-de-eva_k-x_low", "Eva K (German, smallest)", "piper", 21, "false", "German, female; the smallest and fastest, rougher. M-AILABS dataset (BSD-style licence)", "tts"),
        ("piper-de-thorsten-medium", "Thorsten (German, medium)", "piper", 63, "false", "German, male; 22 kHz, clearer on this device's speakers, slower to make (the watch waits longer). Thorsten-Voice dataset, CC0", "tts"),
        ("piper-en-ljspeech-medium", "LJSpeech (English, medium)", "piper", 64, "false", "US English, female; 22 kHz, clearer on this device's speakers, slower to make (the watch waits longer). LJ Speech dataset, public domain", "tts"),
    ]
    # The config key a downloaded model of each kind becomes, its backend key, and the dropdown's text
    # while nothing is installed (ConfigSchema.kt's runtime combos).
    VOICE_KIND_KEYS = {
        "stt": ("voice.local_model", "voice.backend", "No model installed"),
        "tts": ("tts.local_voice", "tts.backend", "No voice installed"),
    }

    def _voice_model(self, mid):
        return next((m for m in self.MOCK_SPEECH_MODELS if m[0] == mid), None)

    def _voice_tick(self):
        """Finish a simulated download whose time is up; installing activates it like the daemon does."""
        d = getattr(self, "voice_dl", None)
        if d and time.time() - d[1] >= 6:
            self.voice_dl = None
            self.voice_installed = getattr(self, "voice_installed", []) + [d[0]]
            m = self._voice_model(d[0])
            self._voice_installed_changed(m[6])
            key, backend, _ = self.VOICE_KIND_KEYS[m[6]]
            # Like PebbleIntegration's VoiceControl callback: a voice always becomes tts.local_voice (and turns
            # tts.backend to Local model only from Off); a speech model only takes over while the backend is
            # Off or Local model. GetConfig spells a combo by its label, so the config holds the name.
            takes_over = m[6] == "tts" or self.config.get(backend) in ("Off", "Local model")
            if takes_over:
                self.config[key] = m[1].replace(",", "")
                self.ConfigChanged(key)
            if takes_over and self.config.get(backend) == "Off":
                self.config[backend] = "Local model"
                self.ConfigChanged(backend)

    def _voice_installed_changed(self, kind):
        key, _, none = self.VOICE_KIND_KEYS[kind]
        # Option labels lose their commas (the options column is a CSV), as ConfigChoice's do.
        names = [m[1].replace(",", "") for m in self.MOCK_SPEECH_MODELS
                 if m[6] == kind and m[0] in getattr(self, "voice_installed", [])]
        field = next(c for c in self.config_schema if c["key"] == key)
        field["options"] = ",".join(names) or none
        # GetConfig reports none chosen ("") while installed models don't include the configured one.
        if self.config.get(key) not in names:
            self.config[key] = "" if names else none

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def VoiceStatus(self):
        self._voice_tick()
        b = self.config.get("voice.backend", "Off")
        if b == "Off":
            return "off:voice.backend is off"
        if b == "Local model":
            m = self.config.get("voice.local_model", "")
            return f"ready:local\t{m}" if m not in ("", "No model installed") else "unavailable:no model chosen (voice.local_model)"
        return f"ready:{b.lower()}"

    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def VoiceModels(self):
        # id \t name \t program \t sizeMb \t state \t recommended \t programInstalled \t note \t kind
        self._voice_tick()
        out = []
        d = getattr(self, "voice_dl", None)
        for mid, name, prog, size, recommended, note, kind in self.MOCK_SPEECH_MODELS:
            if d and d[0] == mid:
                state = f"downloading:{min(99, int((time.time() - d[1]) * 100 / 6))}"
            elif mid in getattr(self, "voice_installed", []):
                state = "installed"
            else:
                state = "available"
            out.append(rec(mid, name, prog, size, state, recommended, "true", note, kind))
        return out

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def VoiceDownloadModel(self, mid):
        self._voice_tick()
        m = self._voice_model(mid)
        if m is None:
            return f"notfound:no model '{mid}' (stoandl voice models)"
        if mid in getattr(self, "voice_installed", []):
            return f"installed:{m[1]} is already installed"
        if getattr(self, "voice_dl", None):
            return "busy:a model is downloading"
        self.voice_dl = (mid, time.time())
        return f"ok:downloading {m[1]} ({m[3]} MB)"

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def VoiceCancelDownload(self):
        if not getattr(self, "voice_dl", None):
            return "none:no download running"
        self.voice_dl = None
        return "ok:cancelled"

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def VoiceRemoveModel(self, mid):
        if mid not in getattr(self, "voice_installed", []):
            return f"notfound:{mid} isn't installed"
        self.voice_installed.remove(mid)
        self._voice_installed_changed(self._voice_model(mid)[6])
        return f"ok:removed {mid}"

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def Transcribe(self, path):
        # The daemon transcribes the WAV/Ogg at the absolute path with voice.backend (up to a minute):
        # ok:<ms>\t<text>. The mock "hears" a fixed sentence after a second, unless speech to text is off.
        st = self.VoiceStatus()
        if not st.startswith("ready:"):
            return st
        if not path.startswith("/") or not os.path.exists(path):
            return f"error:No such file: {path}"
        time.sleep(1)
        return "ok:" + rec(1000, "this is a test of speech to text")

    # --- Text to speech (TtsService): status, and host playback of a test sentence ----------------
    def _tts_status(self):
        b = self.config.get("tts.backend", "Off")
        if b == "Off":
            return "off:tts.backend is off"
        if b == "Local model":
            v = self.config.get("tts.local_voice", "")
            return f"ready:local\t{v}" if v not in ("", "No voice installed") else "unavailable:no voice installed (stoandl voice download)"
        if b == "Custom command":
            c = self.config.get("tts.command", "")
            return f"ready:command\t{c}" if c else "unavailable:tts.command is empty"
        u = self.config.get("tts.url", "")
        return f"ready:http\t{u}" if u else "unavailable:tts.url is empty"

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def TtsStatus(self):
        self._voice_tick()
        return self._tts_status()

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def Speak(self, text):
        # Plays on this computer (pw-play / paplay / aplay); a new call preempts the one playing.
        st = self._tts_status()
        if not st.startswith("ready:"):
            return st
        self.speaking_until = time.time() + 0.08 * len(text)
        return f"ok:speaking {len(text)} characters"

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def StopSpeaking(self):
        if getattr(self, "speaking_until", 0) <= time.time():
            return "none:nothing is being read aloud"
        self.speaking_until = 0
        return "ok:stopped"

    @dbus.service.signal(IFACE, signature="")
    def ExtensionsChanged(self):
        # poke: re-call ExtList. Fired on enable/disable/restart/install/uninstall.
        pass

    @dbus.service.signal(IFACE, signature="ss")
    def ExtensionStateChanged(self, name, state):
        # Finer companion to ExtensionsChanged: an UNSOLICITED per-extension run-state
        # transition the list-level poke can't carry. state ∈ {ready (handshake done /
        # running), exited (process ended, restarting after backoff), quarantined (gave up
        # after rapid failures — won't restart until ExtRestart)}. The GUI records it and
        # overrides a stale polled "running" (the daemon keeps a quarantined ext in its
        # running map). We fire it after enable/restart and on the mock-only crash trigger.
        pass

    @dbus.service.signal(IFACE, signature="")
    def CalendarsChanged(self):
        # The seventh Control signal (per CLAUDE.md/drift-report). Poke: re-call
        # ListCalendars (+ListCalendarSources). The real daemon fires it when an async
        # sync adds/drops calendars AFTER a source CRUD; the Calendars page also keeps a
        # short settle-timer as the fallback. Emitted from the calendar-source mutators.
        pass

    # --- firmware progress walker (pushes FirmwareProgress on a GLib tick) --
    @staticmethod
    def _fw_steps(downgrade):
        """The FirmwareStatus strings one flash walks through, each with an optional side effect.

        A normal flash: download, transfer, `reboot:`. A downgrade on a dual-slot watch (the
        daemon's FirmwareControl since "finish downgrades that go through recovery"): libpebble3
        reboots the watch into recovery WITHOUT transferring, reported as `prf:<version>`; the link
        drops (`notready:`), the watch comes back in PRF (`idle:` until the daemon re-flashes the
        remembered .pbz), then the real transfer runs and ends in `reboot:`. So a client that
        declares success at the first disconnect is wrong by one whole flash.
        """
        flash = [("waiting:", None)] + [(f"inprogress:{p}", None) for p in (20, 40, 60, 80, 100)]
        if downgrade not in ("1", "drop"):
            return [("downloading:core-fw.pbz", None)] * 2 + flash + [("reboot:", "end")]
        nowatch = "notready:No watch connected"
        head = ([("waiting:", None)] + [(f"prf:{DOWNGRADE_VERSION}", None)] * 2
                + [(nowatch, "drop")] + [(nowatch, None)] * 3)
        if downgrade == "drop":
            # Back on normal firmware: the daemon drops the pending .pbz and says so.
            return head + [(DOWNGRADE_DROPPED, "end")]
        return head + [("idle:", "back")] + flash + [("reboot:", "end")]

    def _fw_tick(self, op):
        """Drive a firmware op forward one step and PUSH the phase via FirmwareProgress.

        FirmwareStatus() reads the same step, so the polled path still works as a fallback;
        returns True to keep the GLib timer running, False to stop it once terminal — or once a
        newer flash replaced `op` (its own timer drives that one).
        """
        if self.fw is not op:
            return False
        self.fw["step"] += 1
        status, effect = self.fw["steps"][self.fw["step"]]
        if status.startswith("prf:"):
            self.fw["prf_pending"] = True             # UpdateFirmware answers busy: from here
        if effect == "drop":
            # The reboot into recovery takes the watch off the air.
            self.fw["watch"] = self._connected_name()
            if self.fw["watch"]:
                self.watches[self.fw["watch"]]["state"] = "disconnected"
            self.WatchesChanged()
        elif effect == "back":
            # Reconnected in recovery; the daemon flashes the pending .pbz from here. The real daemon
            # lists such a watch as `recovery`, never `connected` (ConnectedPebbleDeviceInRecovery is
            # not a ConnectedPebbleDevice), and only the firmware/core-dump/logs methods serve it.
            self.fw["prf_pending"] = False
            if self.fw["watch"]:
                self.watches[self.fw["watch"]]["state"] = "recovery"
            self.WatchesChanged()
        # Same (phase, percent, detail) split as the daemon's startSignalEmitters() parse(); its
        # status flow says a bare "notready:" when the watch is gone.
        phase, _, rest = status.partition(":")
        if phase == "inprogress":
            self.FirmwareProgress(phase, int(rest), "")
        else:
            self.FirmwareProgress(phase, -1, "" if phase == "notready" else rest)
        if effect == "end":
            # The watch comes back on its normal firmware: after the post-flash reboot, or, with
            # MOCK_FW_DOWNGRADE=drop, instead of recovery.
            if self.fw["watch"]:
                self.watches[self.fw["watch"]]["state"] = "connected"
            self.fw = None
            self.fw_cached_update = None              # the running version changed: the cached answer is gone
            self.WatchesChanged()                     # link drops → list state changes
            return False
        return True

    def _start_fw_push(self, downgrade=""):
        self.fw = {"steps": self._fw_steps(downgrade), "step": -1, "prf_pending": False, "watch": None}
        GLib.timeout_add(700, self._fw_tick, self.fw)  # ~match the CLI/GUI firmware poll cadence

    # --- language progress walker (pushes LanguageProgress on a GLib tick) --
    def _lang_tick(self):
        """Drive a language install forward one step and PUSH the phase via LanguageProgress.

        Mirrors LanguageStatus()'s walk so the polled path still works as a fallback;
        returns True to keep the GLib timer running, False to stop it once terminal.
        """
        if self.lang is None:
            return False
        p = self.lang["polls"]
        self.lang["polls"] += 1
        if p == 0:
            self.LanguageProgress("downloading", -1, self.lang["name"])
        elif 1 <= p <= 4:
            self.LanguageProgress("installing", p * 25, "")  # 25,50,75,100
        else:
            name = self.lang["name"]
            if self.lang.get("target"):
                self.lang["target"]["installed"] = True
            self.lang = None
            self.LanguageProgress("done", -1, name)  # success → installed
            return False
        return True

    def _start_lang_push(self, name, target):
        self.lang = {"polls": 0, "name": name, "target": target}
        GLib.timeout_add(700, self._lang_tick)  # ~match the firmware push cadence


def main():
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    name = dbus.service.BusName(BUS_NAME, bus)  # claim the well-known name
    mock = MockStoandl(bus, OBJ_PATH)
    print(f"[mock] {BUS_NAME} owning {OBJ_PATH} ({IFACE}) — ready", flush=True)
    # MOCK_FW_AUTOSTART=<seconds>: start a flash that long after startup, as if the CLI had kicked
    # it off — the GUI then only sees FirmwareProgress signals, never its own Update/Sideload call.
    # With MOCK_FW_DOWNGRADE=1 (or drop) it is a downgrade through recovery (see _fw_steps).
    delay = os.environ.get("MOCK_FW_AUTOSTART")
    if delay:
        GLib.timeout_add(int(float(delay) * 1000), lambda: mock._start_fw_push(
            downgrade=os.environ.get("MOCK_FW_DOWNGRADE", "")) and False)
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
