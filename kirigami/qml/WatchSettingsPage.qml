import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui
import "StableRows.js" as StableRows

// Watch "advanced settings" (the WatchPrefs BlobDB the official app exposes). The daemon's
// ListWatchPrefs sends one record per pref: id/type/current/default/allowed/flags/name/description,
// where type ∈ {bool, number, enum, quicklaunch, color, schedule}. We render ONE delegate per type —
// crucially, quicklaunch is an APP PICKER (not a slider setting a uuid), enum/color get real
// combos/pickers and schedule (Quiet Time hours) a validated HH:MM-HH:MM field — and group the ~50
// prefs into labelled sections instead of one undifferentiated list.
Kirigami.ScrollablePage {
    id: page
    objectName: "watchSettings"
    title: "Watch settings"

    // The page holds the daemon's list and two things derived from it, each reassigned only when it
    // really changed (same scheme as GeneralSettingsPage):
    //  - prefShape: [{title, rows:[{id,type}]}], the sections. It is the ONLY thing the Repeaters see,
    //    so rows are created once: opening builds each row once, a pref change builds nothing.
    //  - prefMap: id → the pref plus its precomputed display data (quick-launch options, colour
    //    presets/swatch, schedule hint, the combo index). Entries keep their identity while unchanged
    //    (StableRows.reuse), so a re-read only re-evaluates the rows whose pref moved.
    // [{id,type,current,currentBool,currentInt,default,allowed[],flags[],debug,name,description,(min,max,unit)}]
    property var watchPrefs: []
    property var prefShape: []
    property var prefMap: ({})
    // Launchable app titles for the quick-launch picker (locker watchapps; faces excluded).
    property var appTitles: []
    // Bumped by every pref change (applyPref). A reload() fetch that started before one answers after
    // its synchronous re-read, with prefs read before the set: it then keeps watchPrefs.
    property int editSeq: 0

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    // --- loaders -----------------------------------------------------------
    // On open and when the daemon comes back: asynchronous. A pref change re-reads synchronously
    // instead (applyPref), so its handler can put the control back on the stored value at once.
    function reload() {
        if (!StoandlClient.daemonUp) { page.applyPrefs([], []); return; }
        var edits = page.editSeq;
        StoandlClient.fetch(page, [["listWatchPrefs"], ["listApps"]], function (r) {
            var titles = [];
            var apps = r[1];
            for (var i = 0; i < apps.length; ++i)
                if (apps[i].type !== "watchface")
                    titles.push(apps[i].title);
            page.applyPrefs(edits !== page.editSeq ? page.watchPrefs : r[0], titles);
        });
    }

    // Everything the rows show, from one list: the map before the shape, so a row created by a new
    // shape finds its pref in place.
    function applyPrefs(prefs, titles) {
        if (!StableRows.same(page.appTitles, titles)) page.appTitles = titles;
        page.watchPrefs = prefs;
        var map = {};
        var buckets = {};
        for (var i = 0; i < prefs.length; ++i) {
            var p = Object.assign({}, prefs[i]);
            var o;
            if (p.type === "quicklaunch") {
                p.qlOptions = page.quickOptions(p.current, p.allowed);
                p.qlCurrentLabel = page.quickLabel(p.current);
                o = p.qlOptions.indexOf(p.qlCurrentLabel);
                p.optionIndex = o >= 0 ? o : 0;
            } else if (p.type === "enum") {
                // allowed + current are both display names, so indexOf matches.
                o = (p.allowed || []).indexOf(p.current);
                p.optionIndex = o >= 0 ? o : 0;
            } else if (p.type === "color") {
                p.colorPresetList = page.colorPresets(p.allowed);
                p.colorCss = page.colorHexCss(p.current);
            } else if (p.type === "schedule") {
                p.scheduleHint = page.scheduleHint(p);
            }
            map[p.id] = p;
            for (var s = 0; s < page.sectionDefs.length; ++s) {
                if (page.sectionDefs[s].match(p.id)) {
                    var k = page.sectionDefs[s].key;
                    (buckets[k] || (buckets[k] = [])).push({ id: p.id, type: p.type });
                    break;
                }
            }
        }
        var shape = [];
        for (var d = 0; d < page.sectionDefs.length; ++d) {
            var rows = buckets[page.sectionDefs[d].key];
            if (rows && rows.length) shape.push({ title: page.sectionDefs[d].title, rows: page.pairSchedules(rows) });
        }
        var nm = StableRows.reuse(page.prefMap, map);
        if (nm !== page.prefMap) page.prefMap = nm;
        if (!StableRows.same(page.prefShape, shape)) page.prefShape = shape;
    }

    // Headless smoke (STOANDL_SMOKE_MS): run the schedule validator both ways and round-trip a
    // window through SetWatchPref, so the re-fetched value re-renders the schedule delegate. The hook
    // also runs against a real daemon, so it writes the watch's own window back afterwards (a pinned
    // `watch.dndWeekdaySchedule` would otherwise be rewritten in stoandl.conf too), and writes nothing
    // without a valid one to restore.
    function smokeExercise() {
        var ql = page.prefById("qlBack");
        if (ql)
            console.log("stoandl-smoke: quick launch qlBack='" + page.quickLabel(ql.current) + "' options="
                        + page.quickOptions(ql.current, ql.allowed).join("|"));
        var bad = StoandlClient.normalizeSchedule("25:00-07:00");
        var good = StoandlClient.normalizeSchedule(" 7:5-22:30 ");
        console.log("stoandl-smoke: schedule validator bad='" + bad + "' good='" + good + "'");
        var orig = "";
        for (var i = 0; i < page.watchPrefs.length; ++i)
            if (page.watchPrefs[i].id === "dndWeekdaySchedule")
                orig = StoandlClient.normalizeSchedule(page.watchPrefs[i].current);
        if (orig === "" || good === "") {
            console.log("stoandl-smoke: schedule round-trip skipped: no schedule to restore");
            return;
        }
        page.applyPref("dndWeekdaySchedule", good);
        page.applyPref("dndWeekdaySchedule", orig);
        console.log("stoandl-smoke: schedule round-trip restored " + orig);
    }

    function applyPref(id, value) {
        page.editSeq++;
        var r = StoandlClient.setWatchPref(id, value);
        if (!r.ok)
            page.toast("Setting: " + (r.tail || r.kind));
        // The re-fetch is authoritative; it patches the changed rows only.
        page.applyPrefs(StoandlClient.listWatchPrefs(), page.appTitles);
    }

    // --- quick-launch helpers ---------------------------------------------
    // "off" displays as "Off"; everything else (a system action, an app name, or a raw uuid) shows
    // verbatim. The option list is ["Off", …system actions, …apps] plus the current value if it isn't
    // already in it. The daemon names the system actions (Quiet Time, Backlight, …) in `allowed`
    // between "off" and the "<app name or uuid>" placeholder, and takes those names back.
    function quickLabel(current) {
        return (!current || String(current).toLowerCase() === "off") ? "Off" : current;
    }
    function quickOptions(current, allowed) {
        var actions = (allowed || []).filter(function (a) { return a !== "off" && a.charAt(0) !== "<"; });
        var opts = ["Off"];
        actions.concat(page.appTitles).forEach(function (o) { if (opts.indexOf(o) < 0) opts.push(o); });
        var lbl = page.quickLabel(current);
        if (opts.indexOf(lbl) < 0) opts.push(lbl);
        return opts;
    }

    // --- color helpers ----------------------------------------------------
    // The daemon's color `current` is "0xRRGGBB" and its `allowed` is "RRGGBB|<preset>|…"; the watch
    // takes either a hex or a preset name back. We show a swatch of the current value and let the user
    // pick a named preset (parseColor resolves the name daemon-side).
    function colorHexCss(s) {
        var hex = String(s).replace(/^0x/i, "").replace(/^#/, "");
        return hex.length >= 6 ? ("#" + hex.slice(-6)) : "#000000";
    }
    function colorPresets(allowed) {
        return (allowed || []).filter(function (a) { return a !== "RRGGBB"; });
    }

    // --- schedule helpers ---------------------------------------------------
    // A Quiet Time schedule's hours do nothing until its "<id>Enabled" switch is on
    // (dndWeekdaySchedule ↔ dndWeekdayScheduleEnabled), and the daemon lists the schedules last. So
    // each schedule row moves right under its switch and says what it depends on.
    function prefById(id) {
        for (var i = 0; i < page.watchPrefs.length; ++i)
            if (page.watchPrefs[i].id === id)
                return page.watchPrefs[i];
        return null;
    }
    function scheduleHint(p) {
        var sw = page.prefById(p.id + "Enabled");
        return (p.description ? p.description + " " : "")
             + "Daily, 24-hour clock; an end before the start runs overnight (e.g. 22:00-07:00)."
             + (sw ? " Applies while “" + sw.name + "” is on." : "");
    }
    // Takes the shape rows ({id, type}); the schedule ids match their switch's id + "Enabled".
    function pairSchedules(rows) {
        var out = rows.filter(function (p) { return p.type !== "schedule"; });
        var loose = [];
        rows.forEach(function (p) {
            if (p.type !== "schedule")
                return;
            for (var i = 0; i < out.length; ++i) {
                if (out[i].id === p.id + "Enabled") { out.splice(i + 1, 0, p); return; }
            }
            loose.push(p);
        });
        return out.concat(loose);
    }

    // --- grouping ----------------------------------------------------------
    // Ordered section rules, matched on the stable libpebble pref id. First match wins; anything
    // unmatched (a future libpebble pref) lands in "Other" so nothing is ever dropped.
    readonly property var sectionDefs: [
        { key: "quicklaunch", title: "Quick launch",        match: function (id) { return id.indexOf("ql") === 0; } },
        { key: "display",     title: "Display & backlight", match: function (id) { return id.indexOf("light") === 0 || id === "systemTextSize" || id === "displayOrientationLeftHanded"; } },
        { key: "notif",       title: "Notifications",       match: function (id) { return id.indexOf("notif") === 0 || id === "mask" || id.indexOf("timelineQuickView") === 0; } },
        { key: "quiet",       title: "Quiet Time",          match: function (id) { return id.indexOf("dnd") === 0; } },
        { key: "vibe",        title: "Vibration",           match: function (id) { return id.indexOf("vibe") >= 0; } },
        { key: "music",       title: "Music",               match: function (id) { return id.indexOf("music") === 0; } },
        { key: "motion",      title: "Motion & menus",      match: function (id) { return id === "motionSensitivity" || id === "stationaryMode" || id.indexOf("menuScroll") === 0; } },
        { key: "clock",       title: "Clock & language",    match: function (id) { return id === "clock24h" || id === "timezoneSource" || id === "language"; } },
        { key: "other",       title: "Other",               match: function (id) { return true; } },
    ]

    Connections {
        target: StoandlClient
        function onDaemonUpChanged() { if (StoandlClient.daemonUp) page.reload(); }
    }

    Component.onCompleted: page.reload()

    ColumnLayout {
        spacing: 0

        DaemonPlaceholder {
            visible: !StoandlClient.daemonUp
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
        }

        // No watch connected (or no prefs synced yet). Same top-level placeholder style as the
        // Watch/Health/Apps/Notifications pages.
        Kirigami.PlaceholderMessage {
            visible: StoandlClient.daemonUp && page.watchPrefs.length === 0
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
            icon.name: "chronometer-symbolic"
            text: "No watch settings"
            explanation: "Connect a watch to read and change its settings."
        }

        // One FormHeader + FormCard per non-empty section.
        Repeater {
            model: page.prefShape
            delegate: ColumnLayout {
                id: sectionItem
                required property var modelData
                Layout.fillWidth: true
                spacing: 0

                FormCard.FormHeader { title: sectionItem.modelData.title }

                FormCard.FormCard {
                    Repeater {
                        model: sectionItem.modelData.rows
                        // One Loader per pref. modelData is only {id, type}; the pref itself is looked up
                        // here, on the Loader, where `page` resolves (inside the inline Components it
                        // doesn't — gui/CLAUDE.md, "QML scope gotcha"), so the Components read only
                        // prefLoader.pref.*. They are defined INLINE so they resolve `prefLoader` (a
                        // Loader can't satisfy a required property on a page-scoped component).
                        //
                        // Rows are built asynchronously and hold a row's height until they are ready.
                        delegate: Loader {
                            id: prefLoader
                            required property var modelData
                            readonly property var pref: page.prefMap[modelData.id] || ({})
                            Layout.fillWidth: true
                            Layout.preferredHeight: status === Loader.Ready ? -1 : Kirigami.Units.gridUnit * 3
                            asynchronous: true
                            sourceComponent: modelData.type === "bool" ? boolPref
                                           : modelData.type === "enum" ? enumPref
                                           : modelData.type === "quicklaunch" ? quickPref
                                           : modelData.type === "number" ? numberPref
                                           : modelData.type === "color" ? colorPref
                                           : modelData.type === "schedule" ? schedulePref
                                           : fallbackPref

                            // The rows outlive a change now, so each handler puts its control back on the
                            // re-read pref: a value the watch refused (unchanged, so no binding fires)
                            // would otherwise stay on screen as if it had been stored.
                            Component {
                                id: boolPref
                                FormCard.FormSwitchDelegate {
                                    id: sw
                                    text: prefLoader.pref.name || ""
                                    description: prefLoader.pref.description || ""
                                    // Only the initial value: FormSwitchDelegate assigns `checked` from its
                                    // inner Switch, which drops any binding, so it follows by hand.
                                    checked: prefLoader.pref.currentBool === true
                                    Connections {
                                        target: prefLoader
                                        function onPrefChanged() { sw.checked = prefLoader.pref.currentBool === true; }
                                    }
                                    onToggled: {
                                        page.applyPref(prefLoader.modelData.id, sw.checked ? "true" : "false");
                                        sw.checked = prefLoader.pref.currentBool === true;
                                    }
                                }
                            }

                            Component {
                                id: enumPref
                                FormCard.FormComboBoxDelegate {
                                    text: prefLoader.pref.name || ""
                                    description: prefLoader.pref.description || ""
                                    model: prefLoader.pref.allowed
                                    currentIndex: prefLoader.pref.optionIndex || 0
                                    onActivated: {
                                        page.applyPref(prefLoader.modelData.id, currentValue);
                                        currentIndex = Qt.binding(function () { return prefLoader.pref.optionIndex || 0; });
                                    }
                                }
                            }

                            Component {
                                id: quickPref
                                FormCard.FormComboBoxDelegate {
                                    text: prefLoader.pref.name || ""
                                    description: prefLoader.pref.description || ""
                                    model: prefLoader.pref.qlOptions
                                    currentIndex: prefLoader.pref.optionIndex || 0
                                    // "Off" → the daemon's "off" sentinel; an app name resolves to its uuid daemon-side.
                                    onActivated: {
                                        page.applyPref(prefLoader.modelData.id, currentText === "Off" ? "off" : currentText);
                                        currentIndex = Qt.binding(function () { return prefLoader.pref.optionIndex || 0; });
                                    }
                                }
                            }

                            Component {
                                id: numberPref
                                FormSpinRow {
                                    label: prefLoader.pref.name || ""
                                    description: prefLoader.pref.description || ""
                                    from: prefLoader.pref.min || 0
                                    to: prefLoader.pref.max || 0
                                    unit: prefLoader.pref.unit || ""
                                    value: prefLoader.pref.currentInt >= 0 ? prefLoader.pref.currentInt
                                                                           : (prefLoader.pref.min || 0)
                                    onCommit: (newValue) => page.applyPref(prefLoader.modelData.id, String(newValue))
                                }
                            }

                            // Color: a swatch of the current value + a preset picker (the daemon takes a
                            // preset name back). FormColorDelegate is avoided — it calls i18ndc(), and
                            // this app deliberately links no KF6 C++ (no KLocalizedContext on the engine).
                            Component {
                                id: colorPref
                                FormCard.AbstractFormDelegate {
                                    id: crow
                                    background: null
                                    contentItem: RowLayout {
                                        spacing: Kirigami.Units.largeSpacing
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 0
                                            QQC2.Label {
                                                Layout.fillWidth: true
                                                text: prefLoader.pref.name || ""
                                                elide: Text.ElideRight
                                            }
                                            QQC2.Label {
                                                Layout.fillWidth: true
                                                visible: text !== ""
                                                text: prefLoader.pref.description || ""
                                                elide: Text.ElideRight
                                                font: Kirigami.Theme.smallFont
                                                color: Kirigami.Theme.disabledTextColor
                                            }
                                        }
                                        Rectangle {
                                            Layout.alignment: Qt.AlignVCenter
                                            implicitWidth: Kirigami.Units.iconSizes.smallMedium
                                            implicitHeight: Kirigami.Units.iconSizes.smallMedium
                                            radius: height / 2
                                            color: Qt.color(prefLoader.pref.colorCss || "#000000")
                                            border.width: 1
                                            border.color: Kirigami.Theme.disabledTextColor
                                        }
                                        QQC2.ComboBox {
                                            id: presetBox
                                            model: prefLoader.pref.colorPresetList
                                            // current is a hex, not a preset name → no preselection.
                                            currentIndex: -1
                                            displayText: currentIndex < 0 ? "Choose…" : currentText
                                            // The swatch shows the result; the picker goes back to "Choose…".
                                            onActivated: {
                                                page.applyPref(prefLoader.modelData.id, currentText);
                                                currentIndex = -1;
                                            }
                                        }
                                    }
                                }
                            }

                            // Schedule (Quiet Time hours): a 24 h "HH:MM-HH:MM" window. Checked as typed
                            // with the daemon's own parse rules (StoandlClient.normalizeSchedule), sent
                            // zero-padded on Enter / focus-out only — a per-keystroke commit would write
                            // half-typed windows — and never while invalid.
                            Component {
                                id: schedulePref
                                FormTextRow {
                                    id: srow
                                    // What SetWatchPref would store for the text as typed; "" = it would refuse it.
                                    readonly property string normalized: StoandlClient.normalizeSchedule(srow.value)
                                    label: prefLoader.pref.name || ""
                                    description: prefLoader.pref.scheduleHint || ""
                                    value: prefLoader.pref.current || ""
                                    placeholderText: "HH:MM-HH:MM"
                                    inputMethodHints: Qt.ImhPreferNumbers | Qt.ImhNoPredictiveText
                                    error: srow.normalized === "" ? "Enter a window as HH:MM-HH:MM, e.g. 22:00-07:00" : ""
                                    onEditingFinished: {
                                        if (srow.normalized !== "" && srow.normalized !== prefLoader.pref.current) {
                                            page.applyPref(prefLoader.modelData.id, srow.normalized);
                                            srow.value = Qt.binding(function () { return prefLoader.pref.current || ""; });
                                        }
                                    }
                                }
                            }

                            // Unknown/future type: a read-only row rather than a broken control.
                            Component {
                                id: fallbackPref
                                FormCard.FormTextDelegate {
                                    text: prefLoader.pref.name || ""
                                    description: prefLoader.pref.current || ""
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
