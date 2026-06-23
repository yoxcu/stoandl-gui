#!/usr/bin/env python3
"""Mock of the stoandl daemon's de.yoxcu.stoandl.Control interface.

A stand-in for the real (JVM + BLE) daemon so the Kirigami GUI can be exercised
headlessly. It is STATEFUL: mutating calls update in-memory state, and the
long-running ops (Pair/Firmware/Language) walk pending -> terminal over a few
polls — so the GUI's "re-fetch after every mutation" path and the poll loops both
light up.

Covers the full surface the GUI uses: the 51 documented control methods that the
new screens touch (Watch, Apps/Faces, Extensions, Notifications, Settings) PLUS
the daemon-side hooks added in this milestone (handoff §5). The hooks are flagged
"HOOK #n" inline; they are the new D-Bus contract the real Kotlin daemon must grow
to match (see the drift report). Returns follow docs/handoff/dbus-interface.md:
status strings are "kind:tail" with tab-separated fields; list methods return one
tab-joined record per element.

Run inside a session bus, e.g.:  dbus-run-session -- python3 mock_stoandl.py
"""

import base64
import json
import time

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

BUS_NAME = "de.yoxcu.stoandl"
OBJ_PATH = "/de/yoxcu/stoandl"
IFACE = "de.yoxcu.stoandl.Control"

# The numeric-comparison code surfaced as confirm:<code> until ConfirmPairing answers.
PAIR_CODE = "481516"

# PebbleOS changelog (HOOK: appended to CheckFirmware so the GUI's "What's new" works).
CHANGELOG_URL = "https://ndocs.repebble.com/PebbleOS-Changelog-25efbb55ea84801da04bfcf73c9346e1"


def rec(*fields):
    """Join fields into one tab-separated record (the `as` element format)."""
    return "\t".join(str(f) for f in fields)


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
        # Host Bluetooth on/usable (BluetoothStatus). Set False to exercise the GUI's BT-off state.
        self.bt_on = True
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
             "flags": ["config"], "title": "Kalk", "developer": "Vinch"},
            {"uuid": "1f03293d", "type": "watchapp", "order": 4,
             "flags": ["system", "synced"], "title": "Music", "developer": "Pebble"},
            {"uuid": "36d8c6ed", "type": "watchapp", "order": 5,
             "flags": ["system", "synced"], "title": "Health", "developer": "Pebble"},
            {"uuid": "07e0d9cb", "type": "watchapp", "order": 6,
             "flags": ["system", "synced"], "title": "Settings", "developer": "Pebble"},
            {"uuid": "a4d3f0b9", "type": "watchapp", "order": 7,
             "flags": ["sideloaded", "config", "synced"], "title": "Pebblemap", "developer": "katharostech"},
            {"uuid": "c91b77a0", "type": "watchapp", "order": 8,
             "flags": ["sideloaded"], "title": "Tezel", "developer": "lavers"},
        ]
        self._sideload_seq = 0
        # Extensions. HOOK #7: `config` (none|url|schema) + `description` fields added.
        self.exts = [
            {"name": "Matrix", "installed": True, "enabled": True, "running": True,
             "config": "url", "description": "Messages on the wrist + canned replies, E2EE"},
            {"name": "Find My Phone", "installed": True, "enabled": True, "running": True,
             "config": "none", "description": "Ring this device from the watch"},
            {"name": "Signal", "installed": True, "enabled": False, "running": False,
             "config": "schema", "description": "Signal messages + quick replies"},
            {"name": "SMS Bridge", "installed": False, "enabled": False, "running": False,
             "config": "schema", "description": "Forward & reply to SMS over ModemManager"},
        ]
        self._ext_seq = 0
        # HOOK #7 (schema backend): per-extension typed config. schema = the manifest;
        # values = current settings. Two extensions declare config=schema above.
        self.ext_schema = {
            "Signal": [
                {"key": "phone", "type": "string", "label": "Linked phone number"},
                {"key": "token", "type": "string", "label": "Device token", "secret": True},
                {"key": "interval", "type": "int", "label": "Poll interval (s)"},
                {"key": "replies", "type": "bool", "label": "Allow quick replies"},
            ],
            "SMS Bridge": [
                {"key": "modem", "type": "enum", "label": "Modem", "options": ["ModemManager", "oFono"]},
                {"key": "country", "type": "string", "label": "Default country code"},
                {"key": "delivery", "type": "bool", "label": "Delivery reports"},
            ],
        }
        self.ext_values = {
            "Signal": {"phone": "+1 555 0123", "token": "", "interval": 20, "replies": True},
            "SMS Bridge": {"modem": "ModemManager", "country": "+1", "delivery": False},
        }
        # HOOK #5: sync services — runtime master on/off + availability + last-sync.
        # service -> {enabled, available, lastSync}.
        self.sync = {
            "notifications": {"enabled": True, "available": True, "lastSync": "live"},
            "weather": {"enabled": True, "available": True, "lastSync": "8 min ago"},
            "calendar": {"enabled": True, "available": True, "lastSync": "12 min ago"},
            "music": {"enabled": True, "available": True, "lastSync": "live"},
            "health": {"enabled": False, "available": True, "lastSync": "never"},
            "dnd": {"enabled": True, "available": True, "lastSync": "synced"},
        }
        self.calendars = [
            {"id": "personal@local", "name": "Personal", "enabled": True},
            {"id": "work@corp",      "name": "Work",     "enabled": True},
            {"id": "holidays@public","name": "Holidays", "enabled": False},
        ]
        # Watch advanced settings (ListWatchPrefs / SetWatchPref). This MIRRORS the real daemon's
        # WatchPrefsControl.list() record EXACTLY so the GUI is exercised against the true contract:
        #   id \t type \t current \t default \t allowed \t flags \t name \t description
        # type ∈ {bool, number, enum, quicklaunch, color}; `allowed` is PIPE-separated (the real
        # daemon joins option/range lists with '|', NOT ','); enum current/allowed use DISPLAY names;
        # number current/default carry the unit ("3000 ms"); quicklaunch current is an app name / "off"
        # / a raw uuid; color is "0xRRGGBB"; flags carries "debug" for advanced/debug-only prefs. The
        # ids match libpebble3's WatchPref ids so the GUI's category grouping (keyed on id) applies.
        self.prefs = [
            # --- Quick Launch (quicklaunch: app name or "off") ---
            {"id": "qlUp", "type": "quicklaunch", "current": "Music", "default": "off",
             "allowed": "off|<app name or uuid>", "flags": "",
             "name": "Quick Launch: Hold Up", "description": "App launched by a long up-press"},
            {"id": "qlDown", "type": "quicklaunch", "current": "off", "default": "off",
             "allowed": "off|<app name or uuid>", "flags": "",
             "name": "Quick Launch: Hold Down", "description": "App launched by a long down-press"},
            {"id": "qlSelect", "type": "quicklaunch", "current": "off", "default": "off",
             "allowed": "off|<app name or uuid>", "flags": "",
             "name": "Quick Launch: Hold Select", "description": "App launched by a long select-press"},
            {"id": "qlSingleClickUp", "type": "quicklaunch", "current": "Health", "default": "Health",
             "allowed": "off|<app name or uuid>", "flags": "",
             "name": "Quick Launch: Tap Up", "description": "App launched by a tap of the up button"},
            # --- Display & Backlight ---
            {"id": "lightEnabled", "type": "bool", "current": "true", "default": "true",
             "allowed": "true|false", "flags": "", "name": "Backlight",
             "description": "Light the screen on button press"},
            {"id": "lightMotion", "type": "bool", "current": "true", "default": "true",
             "allowed": "true|false", "flags": "", "name": "Backlight Motion",
             "description": "Turn on backlight by flicking wrist"},
            {"id": "lightIntensity", "type": "enum", "current": "Medium", "default": "Medium",
             "allowed": "Low|Medium|High|Blinding", "flags": "", "name": "Backlight Intensity",
             "description": "Maximum backlight brightness when on"},
            {"id": "lightTimeoutMs", "type": "number", "current": "3000 ms", "default": "3000 ms",
             "allowed": "1..10000 ms", "flags": "", "name": "Backlight Timeout",
             "description": "How long the backlight stays on"},
            {"id": "lightColor", "type": "color", "current": "0xF0D0B0", "default": "0xF0D0B0",
             "allowed": "RRGGBB|Red|Orange|Yellow|Lime|Green|Cyan|Blue|Purple|Magenta|Pink|Warm White|Cool White",
             "flags": "", "name": "Backlight Color",
             "description": "LED color used when the backlight is on (color watches only)"},
            {"id": "textStyle", "type": "enum", "current": "Default", "default": "Default",
             "allowed": "Smaller|Default|Larger", "flags": "", "name": "Text Size",
             "description": ""},
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
             "allowed": "0..600000 ms", "flags": "", "name": "Notification Timeout",
             "description": "Notifications time out after this period (unless in Quiet Time)"},
            {"id": "timelineQuickViewEnabled", "type": "bool", "current": "true", "default": "true",
             "allowed": "true|false", "flags": "", "name": "Timeline Quick View",
             "description": "Show upcoming events below the watchface"},
            # --- Quiet Time ---
            {"id": "dndManuallyEnabled", "type": "bool", "current": "false", "default": "false",
             "allowed": "true|false", "flags": "", "name": "Quiet Time - Manual",
             "description": "Mute notifications and keep them on-screen without a timeout"},
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
            {"id": "langEnglish", "type": "bool", "current": "false", "default": "false",
             "allowed": "true|false", "flags": "", "name": "Language: English", "description": ""},
        ]
        # System screen: firmware + language op state, language catalog.
        self.fw = None    # None when idle, else {"polls": n}
        self.lang = None  # None when idle, else {"polls": n, "name": ...}
        self.languages = [
            {"id": "en_US", "iso": "English (US)", "name": "English (US)", "installed": True,  "source": "github"},
            {"id": "de_DE", "iso": "Deutsch",      "name": "German",       "installed": False, "source": "rebble"},
            {"id": "fr_FR", "iso": "Francais",     "name": "French",       "installed": False, "source": "rebble"},
            {"id": "ja_JP", "iso": "Nihongo",      "name": "Japanese",     "installed": False, "source": "github"},
        ]
        # HOOK #10: daemon config (stoandl.conf) over D-Bus, schema-driven.
        self.config_schema = [
            {"key": "units", "type": "combo", "label": "Units",
             "options": "Metric,Imperial", "desc": ""},
            {"key": "weather_provider", "type": "combo", "label": "Weather provider",
             "options": "Open-Meteo", "desc": ""},
            {"key": "auto_reconnect", "type": "toggle", "label": "Reconnect automatically",
             "options": "", "desc": "Reconnect when the watch comes back in range"},
            {"key": "calendar_window", "type": "combo", "label": "Timeline window",
             "options": "1 day,3 days,7 days", "desc": ""},
            {"key": "log_level", "type": "combo", "label": "Log level",
             "options": "error,info,debug", "desc": ""},
        ]
        self.config = {
            "units": "Metric", "weather_provider": "Open-Meteo", "auto_reconnect": "true",
            "calendar_window": "3 days", "log_level": "info",
        }
        # HOOK #8: health activity series + today totals.
        # Last night ~23:20 → 07:04 (epoch seconds, midnight-of-today anchored).
        midnight = int(time.time()) // 86400 * 86400
        bedtime = midnight - 40 * 60        # 23:20 yesterday
        wakeup = midnight + 7 * 3600 + 4 * 60  # 07:04 today
        self.health = {
            "stepsToday": 7432, "stepGoal": 10000, "distanceKm": "5.4", "kcal": 312, "activeMin": 52,
            "stepWeekAvg": 6890, "stepTrendPct": 8,
            "sleepTotalMin": 444, "sleepDeepMin": 108, "sleepLightMin": 336,
            "sleepBedtime": bedtime, "sleepWakeup": wakeup, "sleepTypicalMin": 426,
            "sleepAvgMin": 426, "sleepTrendPct": 6,
            "restingHr": 58, "currentHr": 72, "hrMin": 54, "hrMax": 121, "hrAvailable": "yes",
            "lastSync": "2 min ago",
            "days": ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
            "stepWeek": [6210, 8140, 5390, 9320, 7432, None, None],
            # Sleep timeline (startFraction, widthFraction, isDeep) over a 6 PM→noon window;
            # light container first, deep blocks last (drawn on top).
            "sleepTimeline": [
                (0.296, 0.435, 0),
                (0.35, 0.03, 1), (0.46, 0.035, 1), (0.58, 0.03, 1), (0.66, 0.025, 1),
            ],
            "heartDay": [60, 58, 57, 59, 61, 64, 70, 88, 95, 79, 72, 68,
                         66, 64, 70, 82, 90, 78, 71, 66, 61, 58, 57, 60],
        }
        # Notifications (per-app store + master forwarding via sync["notifications"]).
        self.notif_apps = [
            {"name": "Signal",   "mute": "never",  "color": "default", "icon": "default", "vibe": "Double",   "last": 1718900000},
            {"name": "Matrix",   "mute": "never",  "color": "default", "icon": "default", "vibe": "Standard", "last": 1718901200},
            {"name": "Gmail",    "mute": "never",  "color": "default", "icon": "default", "vibe": "Subtle",   "last": 1718890000},
            {"name": "Phone",    "mute": "never",  "color": "default", "icon": "default", "vibe": "Long",     "last": 1718880000},
            {"name": "Calendar", "mute": "always", "color": "default", "icon": "calendar","vibe": "Standard", "last": 1718800000},
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
        # HOOK #4: `transport` (ble|classic, empty when disconnected) appended.
        return [rec(n, w["state"], w["battery"],
                    w["transport"] if w["state"] == "connected" else "")
                for n, w in self.watches.items()]

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def Battery(self):
        name = self._connected_name()
        if name is None:
            return "notready:"
        level = self.watches[name]["battery"] or "0"
        return f"ok:{rec(name, level)}"

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
        match = self._resolve(name)
        if match is None:
            return f"notfound:no known watch matching '{name}'"
        self._set_connected(match)
        return f"ok:connected to {match}"

    def _resolve(self, query):
        if query in self.watches:
            return query
        hits = [n for n in self.watches if query.lower() in n.lower()]
        return hits[0] if len(hits) == 1 else None

    # --- Pair / PairStatus / Repair / Unpair -------------------------------
    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def Pair(self):
        self.pairing = {"phase": "search", "polls": 0, "newName": "Pebble (new)", "decision": None}
        return "ok:pairing window open"

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def Repair(self, name):
        match = self._resolve(name)
        if match is None:
            return f"notfound:no known watch matching '{name}'"
        info = self.watches.pop(match)
        self.pairing = {"phase": "search", "polls": 0, "newName": match, "restore": info, "decision": None}
        return "ok:re-pairing window open"

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def PairStatus(self):
        # HOOK (numeric comparison): walk search -> confirm:<code> -> (await ConfirmPairing) -> done.
        p = self.pairing
        if p is None:
            return "timeout:no pairing in progress"
        if p["phase"] == "search":
            p["polls"] += 1
            if p["polls"] < 2:
                return "pending:Searching for a watch in pairing mode…"
            p["phase"] = "confirm"
            return f"confirm:{PAIR_CODE}"
        if p["phase"] == "confirm":
            if p["decision"] is None:
                return f"confirm:{PAIR_CODE}"      # park until ConfirmPairing answers
            if not p["decision"]:
                self.pairing = None
                return "error:Pairing declined"
            p["phase"] = "done"
            return "pending:Completing pairing…"
        # phase == "done": register + connect the watch.
        name = p["newName"]
        restore = p.get("restore")
        self.watches[name] = restore or {
            "state": "disconnected", "battery": "", "transport": "ble",
            "model": "Pebble 2 HR", "platform": "DIORITE", "firmware": "4.4.2",
            "serial": "Q40NEW00000", "code": "NEW1", "lastSync": "just now",
        }
        self._set_connected(name)
        self.pairing = None
        return "ok:paired"

    @dbus.service.method(IFACE, in_signature="b", out_signature="s")
    def ConfirmPairing(self, accept):
        # HOOK: answer a confirm:<code> from PairStatus (numeric comparison).
        if self.pairing is None or self.pairing.get("phase") != "confirm":
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
                    a["title"], a["developer"]) for a in self.apps]

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

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def SideloadApp(self, path):
        if not path:
            return "error:empty path"
        base = path.rsplit("/", 1)[-1]
        title = base[:-4] if base.endswith(".pbw") else base
        self._sideload_seq += 1
        order = max((a["order"] for a in self.apps), default=-1) + 1
        self.apps.append({
            "uuid": f"side{self._sideload_seq:04d}", "type": "watchapp",
            "order": order, "flags": ["sideloaded"], "title": title, "developer": "Sideloaded",
        })
        self.LockerChanged()
        return f"ok:installed {title}"

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def OpenConfig(self, query):
        app = self._resolve_app(query)
        if app is None or app == "ambiguous":
            return ""  # no config / not resolvable
        if "config" not in app["flags"]:
            return ""  # app has no config page
        return f"ok:https://clay.local/config?uuid={app['uuid']}"

    @dbus.service.method(IFACE, in_signature="s", out_signature="")
    def WebviewClose(self, settings_json):
        pass  # v1 GUI skips the round-trip

    # --- Extensions / plugins ----------------------------------------------
    def _resolve_ext(self, query):
        for e in self.exts:
            if e["name"] == query:
                return e
        hits = [e for e in self.exts if query.lower() in e["name"].lower()]
        return hits[0] if len(hits) == 1 else ("ambiguous" if hits else None)

    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def ExtList(self):
        # HOOK #7: `config` (none|url|schema) + `description` appended to the record.
        return [rec(e["name"],
                    "installed" if e["installed"] else "missing",
                    "enabled" if e["enabled"] else "disabled",
                    "running" if e["running"] else "stopped",
                    e["config"], e["description"]) for e in self.exts]

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
    def ExtOpenConfig(self, query):
        # HOOK #7 (url backend): config URL on stoandl's embedded HTTP server.
        e = self._resolve_ext(query)
        if e is None or e == "ambiguous":
            return f"notfound:no extension matching '{query}'"
        if e["config"] == "url":
            return f"ok:http://127.0.0.1:8718/ext/{e['name'].lower().replace(' ', '-')}"
        if e["config"] == "schema":
            return "error:this extension uses a native config form"
        return "none:"

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
        if not self.sync["weather"]["enabled"]:
            return "error:weather is not enabled in config"
        self.sync["weather"]["lastSync"] = "just now"
        return "ok:weather pushed"

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def SyncCalendar(self):
        if not self.sync["calendar"]["enabled"]:
            return "error:calendar is not enabled in config"
        self.sync["calendar"]["lastSync"] = "just now"
        return "ok:calendar pins updated"

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def SyncHealth(self):
        if not self.sync["health"]["enabled"]:
            return "error:health is not enabled in config"
        self.sync["health"]["lastSync"] = "just now"
        self.health["lastSync"] = "just now"
        return "ok:health data refreshed"

    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def GetSyncStatus(self):
        # HOOK #5: service\tenabled\tavailable\tlastSync.
        return [rec(s, "enabled" if v["enabled"] else "disabled",
                    "available" if v["available"] else "unavailable", v["lastSync"])
                for s, v in self.sync.items()]

    @dbus.service.method(IFACE, in_signature="sb", out_signature="s")
    def SetSyncEnabled(self, service, enabled):
        # HOOK #5: rewrite stoandl.conf + start/stop the live service.
        if service not in self.sync:
            return f"notfound:no sync service '{service}'"
        self.sync[service]["enabled"] = bool(enabled)
        return f"ok:{service} {'enabled' if enabled else 'disabled'}"

    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def ListCalendars(self):
        return [rec(c["id"], c["name"], "enabled" if c["enabled"] else "disabled")
                for c in self.calendars]

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
    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def ListWatchPrefs(self):
        return [rec(p["id"], p["type"], p["current"], p["default"], p["allowed"],
                    p["flags"], p["name"], p["description"]) for p in self.prefs]

    # Backlight color presets — name → 0xRRGGBB — matching libpebble3's BACKLIGHT_COLOR_PRESETS
    # (WatchPrefEntity.kt). The daemon's parseColor() resolves a preset NAME first, then a hex.
    COLOR_PRESETS = {
        "red": "0xFF0000", "orange": "0xFF7F00", "yellow": "0xFFFF00", "lime": "0x7FFF00",
        "green": "0x00FF00", "cyan": "0x00FFFF", "blue": "0x0000FF", "purple": "0x7F00FF",
        "magenta": "0xFF00FF", "pink": "0xFF66CC", "warm white": "0xF0D0B0", "cool white": "0xFFFFFF",
    }

    @dbus.service.method(IFACE, in_signature="ss", out_signature="s")
    def SetWatchPref(self, pref_id, value):
        for p in self.prefs:
            if p["id"] == pref_id:
                # Mirror the daemon's parse* + format() round-trip on read-back: a color resolves a
                # preset NAME (or a hex) to 0xRRGGBB; a number re-appends its unit; an "off"
                # quicklaunch collapses to "off". Everything else stores the value verbatim.
                if p["type"] == "color":
                    preset = self.COLOR_PRESETS.get(value.strip().lower())
                    if preset is not None:
                        p["current"] = preset
                    else:
                        hexv = value.lstrip("#").removeprefix("0x").removeprefix("0X")[-6:].upper()
                        p["current"] = "0x" + hexv.rjust(6, "0")
                elif p["type"] == "number":
                    unit = p["allowed"].split(" ", 1)[1] if " " in p["allowed"] else ""
                    p["current"] = (value.strip() + (" " + unit if unit else "")).strip()
                elif p["type"] == "quicklaunch" and value.strip().lower() in ("", "off", "none", "disabled"):
                    p["current"] = "off"
                else:
                    p["current"] = value
                return f"ok:{p['name']} set to {p['current']}"
        return f"notfound:no setting '{pref_id}'"

    # --- Notifications -----------------------------------------------------
    def _resolve_notif(self, query):
        for a in self.notif_apps:
            if a["name"].lower() == query.lower():
                return a
        hits = [a for a in self.notif_apps if query.lower() in a["name"].lower()]
        return hits[0] if len(hits) == 1 else None

    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def NotifList(self):
        return [rec(a["name"], a["mute"], a["color"], a["icon"], a["vibe"], a["last"])
                for a in self.notif_apps]

    @dbus.service.method(IFACE, in_signature="ss", out_signature="s")
    def NotifSetMute(self, query, spec):
        a = self._resolve_notif(query)
        if a is None:
            return f"notfound:no app matching '{query}'"
        a["mute"] = spec if spec else "never"
        return f"ok:{a['name']} mute = {a['mute']}"

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def NotifSetMuteAll(self, spec):
        for a in self.notif_apps:
            a["mute"] = spec if spec else "never"
        return f"ok:all apps mute = {spec or 'never'}"

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
    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def GetHealthSummary(self):
        h = self.health
        return "ok:" + rec(
            h["stepsToday"], h["stepGoal"], h["distanceKm"], h["kcal"], h["activeMin"],
            h["stepWeekAvg"], h["stepTrendPct"],
            h["sleepTotalMin"], h["sleepDeepMin"], h["sleepLightMin"],
            h["sleepBedtime"], h["sleepWakeup"], h["sleepTypicalMin"],
            h["sleepAvgMin"], h["sleepTrendPct"],
            h["restingHr"], h["currentHr"], h["hrMin"], h["hrMax"], h["hrAvailable"],
            h["lastSync"])

    @dbus.service.method(IFACE, in_signature="s", out_signature="as")
    def GetHealthSeries(self, metric):
        h = self.health
        if metric == "steps":
            return [rec(d, "" if v is None else v) for d, v in zip(h["days"], h["stepWeek"])]
        if metric == "sleep":
            # Last night's light/deep timeline: startFraction \t widthFraction \t isDeep(0|1).
            return [rec(s, w, deep) for (s, w, deep) in h["sleepTimeline"]]
        if metric == "heart":
            if h["hrAvailable"] != "yes":
                return []
            return [rec(i, v) for i, v in enumerate(h["heartDay"])]
        return []

    # --- Daemon config (HOOK #10) ------------------------------------------
    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def GetConfigSchema(self):
        return [rec(c["key"], c["type"], c["label"], c["options"], c["desc"])
                for c in self.config_schema]

    @dbus.service.method(IFACE, in_signature="", out_signature="as")
    def GetConfig(self):
        return [rec(k, v) for k, v in self.config.items()]

    @dbus.service.method(IFACE, in_signature="ss", out_signature="s")
    def SetConfig(self, key, value):
        known = {c["key"] for c in self.config_schema}
        if key not in known:
            return f"notfound:no config key '{key}'"
        self.config[key] = value
        return f"ok:{key} = {value}"

    # --- Firmware ----------------------------------------------------------
    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def CheckFirmware(self):
        # HOOK: changelog URL appended as a 7th field for the "What's new" link.
        # ok:<board>\t<current>\t<latest>\t<asset>\t<yes|no>\t<source>\t<changelogUrl>
        return rec("ok:snowy_s3", "4.4.2", "4.4.3", "core-fw.pbz", "yes", "github", CHANGELOG_URL)

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def UpdateFirmware(self):
        self._start_fw_push()   # walk + push FirmwareProgress on a GLib tick
        return rec("ok:snowy_s3", "4.4.2", "4.4.3", "core-fw.pbz")

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def SideloadFirmware(self, path):
        if not path:
            return "error:empty path"
        self._start_fw_push()
        return f"ok:flashing {path.rsplit('/', 1)[-1]}"

    @dbus.service.method(IFACE, in_signature="", out_signature="s")
    def FirmwareStatus(self):
        # Non-advancing SNAPSHOT of the op the _fw_tick walker drives — the GLib walker owns
        # the step counter and pushes FirmwareProgress; this is just the polled fallback that
        # reports the current phase (so polling and the signal never double-advance the walk).
        if self.fw is None:
            return "idle:"
        p = self.fw["polls"]
        if p <= 1:
            return "downloading:core-fw.pbz"
        if p == 2:
            return "waiting:"
        if 3 <= p <= 7:
            return f"inprogress:{(p - 2) * 20}"   # 20,40,60,80,100
        return "reboot:"                           # success -> watch reboots

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
        png = base64.b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
        try:
            with open(path, "wb") as f:
                f.write(png)
        except OSError as e:
            return f"error:{e}"
        return rec(f"ok:{path}", "1", "1")

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def GatherLogs(self, path):
        try:
            with open(path, "w") as f:
                f.write("[mock] stoandl watch log\nbattery 72%\nfw 4.4.2\n")
        except OSError as e:
            return f"error:{e}"
        return f"ok:{path}"

    @dbus.service.method(IFACE, in_signature="s", out_signature="s")
    def GetCoreDump(self, path):
        if self._connected_name() is None:
            return "notready:"
        try:
            with open(path, "wb") as f:
                f.write(b"\x7fCORE[mock coredump]")
        except OSError as e:
            return f"error:{e}"
        return f"ok:{path}"

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

    # --- firmware progress walker (pushes FirmwareProgress on a GLib tick) --
    def _fw_tick(self):
        """Drive a firmware op forward one step and PUSH the phase via FirmwareProgress.

        Mirrors FirmwareStatus()'s walk so the polled path still works as a fallback;
        returns True to keep the GLib timer running, False to stop it once terminal.
        """
        if self.fw is None:
            return False
        p = self.fw["polls"]
        self.fw["polls"] += 1
        if p <= 1:
            self.FirmwareProgress("downloading", -1, "core-fw.pbz")
        elif p == 2:
            self.FirmwareProgress("waiting", -1, "")
        elif 3 <= p <= 7:
            self.FirmwareProgress("inprogress", (p - 2) * 20, "")  # 20,40,60,80,100
        else:
            self.fw = None
            self.FirmwareProgress("reboot", -1, "")  # success → watch reboots
            self.WatchesChanged()                     # link drops → list state changes
            return False
        return True

    def _start_fw_push(self):
        self.fw = {"polls": 0}
        GLib.timeout_add(700, self._fw_tick)  # ~match the CLI/GUI firmware poll cadence

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
    MockStoandl(bus, OBJ_PATH)
    print(f"[mock] {BUS_NAME} owning {OBJ_PATH} ({IFACE}) — ready", flush=True)
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
