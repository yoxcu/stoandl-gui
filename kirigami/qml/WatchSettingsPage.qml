import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui
import "StableRows.js" as StableRows

// Watch "advanced settings" (the WatchPrefs BlobDB the official app exposes). The daemon's
// ListWatchPrefs sends one record per pref: id/type/current/default/allowed/flags/name/description/
// section/help/requires, where type ∈ {bool, number, enum, quicklaunch, color, schedule}. We render ONE
// delegate per type — crucially, quicklaunch is an APP PICKER (not a slider setting a uuid), enum/color
// open the page's one OptionPicker and schedule (Quiet Time hours) a validated HH:MM-HH:MM field — under
// the daemon's sections, in the order it lists them. Its "Advanced" section (diagnostic prefs) starts
// collapsed. A pref that only matters while another has some value (`requires`) is disabled until then
// and says so; its (?) holds the daemon's help and the default.
Kirigami.ScrollablePage {
    id: page
    objectName: "watchSettings"
    title: "Watch preferences"

    /** A pref id to scroll to and highlight (the Settings search); "" = none. */
    property string focusId: ""

    // The page holds the daemon's list and two things derived from it, each reassigned only when it
    // really changed (same scheme as SchemaSections):
    //  - prefShape: [{title, advanced, rows:[{id,type}]}], the sections. It is the ONLY thing the
    //    Repeaters see, so rows are created once: opening builds each row once, a pref change builds nothing.
    //  - prefMap: id → the pref plus its precomputed display data (quick-launch options, colour
    //    presets/swatch, the picker's checked index, the row's description, help and whether its
    //    `requires` holds). Entries keep their identity while unchanged (StableRows.reuse), so a re-read
    //    only re-evaluates the rows whose pref moved.
    // [{id,type,current,currentBool,currentInt,default,allowed[],flags[],debug,name,description,section,help,
    //   requires[],(min,max,unit,scale)}]
    property var watchPrefs: []
    property var prefShape: []
    property var prefMap: ({})
    // Launchable app titles for the quick-launch picker (locker watchapps; faces excluded).
    property var appTitles: []
    // Bumped by every pref change (applyPref). A reload() fetch that started before one answers after
    // its synchronous re-read, with prefs read before the set: it then keeps watchPrefs.
    property int editSeq: 0
    property bool advancedOpen: false
    readonly property int advancedCount: page.prefShape.reduce(function (n, g) { return n + (g.advanced ? g.rows.length : 0); }, 0)
    readonly property bool hasNormal: page.prefShape.some(function (g) { return !g.advanced; })

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
        var order = [];
        for (var i = 0; i < prefs.length; ++i) {
            var p = Object.assign({}, prefs[i]);
            p.enabled = page.requiresMet(p.requires);
            p.subtitle = p.enabled ? p.description
                       : (p.description !== "" ? p.description + " · " : "") + page.usedWhen(p.requires);
            p.helpText = page.helpText(p);
            var o;
            if (p.type === "quicklaunch") {
                p.qlOptions = page.quickOptions(p.current, p.allowed);
                p.qlCurrentLabel = page.quickLabel(p.current);
                o = p.qlOptions.indexOf(p.qlCurrentLabel);
                p.optionIndex = o >= 0 ? o : 0;
            } else if (p.type === "enum") {
                // allowed + current are both display names, so indexOf matches.
                p.optionIndex = (p.allowed || []).indexOf(p.current);
            } else if (p.type === "color") {
                p.colorPresetList = page.colorPresets(p.allowed);
                p.colorCss = page.colorHexCss(p.current);
            }
            map[p.id] = p;
            // The daemon's sections, in the order it lists them; "Advanced" (diagnostic prefs) last.
            if (!buckets[p.section]) { buckets[p.section] = []; order.push(p.section); }
            buckets[p.section].push({ id: p.id, type: p.type });
        }
        var sections = order.map(function (t) { return { title: t, advanced: t === "Advanced", rows: page.pairSchedules(buckets[t]) }; });
        var shape = sections.filter(function (g) { return !g.advanced; })
                            .concat(sections.filter(function (g) { return g.advanced; }));
        var nm = StableRows.reuse(page.prefMap, map);
        if (nm !== page.prefMap) page.prefMap = nm;
        if (!StableRows.same(page.prefShape, shape)) {
            if (page.focusId !== "" && shape.some(function (g) {
                    return g.advanced && g.rows.some(function (r) { return r.id === page.focusId; }); }))
                page.advancedOpen = true;
            page.prefShape = shape;
        }
    }

    // --- row texts ---------------------------------------------------------
    // A value as its row shows it: a switch as on/off, quick launch's "off" as Off.
    function valueText(v) {
        return v === "true" ? "on" : v === "false" ? "off" : String(v).toLowerCase() === "off" ? "Off" : v;
    }
    function helpText(p) {
        var d = p.type === "color" || p.default === "" ? "" : "Default: " + page.valueText(p.default) + ".";
        return [p.help || "", d].filter(function (x) { return x !== ""; }).join(" ");
    }
    // `requires` is in ListWatchPrefs' own `current` spelling; a pref the watch doesn't list doesn't hold
    // the row back.
    function requiresMet(reqs) {
        if (!reqs || reqs.length === 0) return true;
        return reqs.some(function (a) {
            var q = page.prefById(a.key);
            return q === null || ((q.current === a.value) !== a.negate);
        });
    }
    function usedWhen(reqs) {
        return "Used when " + reqs.map(function (a) {
            var q = page.prefById(a.key);
            return "“" + (q ? q.name : a.key) + "” " + (a.negate ? "isn't " : "is ") + page.valueText(a.value);
        }).join(" or ");
    }

    function resetAll() {
        var r = StoandlClient.resetWatchPrefs();
        page.toast(r.ok ? r.tail : r.notready ? "Connect a watch first" : "Reset: " + (r.tail || r.kind));
        page.editSeq++;
        page.applyPrefs(StoandlClient.listWatchPrefs(), page.appTitles);
    }

    // Headless smoke (STOANDL_SMOKE_MS): press a quick-launch row and pick its stored option in the
    // picker, run the schedule validator both ways and round-trip a
    // window through SetWatchPref, so the re-fetched value re-renders the schedule delegate. The hook
    // also runs against a real daemon, so it writes the watch's own window back afterwards (a pinned
    // `watch.dndWeekdaySchedule` would otherwise be rewritten in stoandl.conf too), and writes nothing
    // without a valid one to restore.
    function smokeExercise() {
        // The daemon's sections, a row its `requires` holds back, the timeout in seconds and a row's help.
        var gated = Object.keys(page.prefMap).filter(function (id) { return page.prefMap[id].enabled === false; });
        var nwt = page.prefMap["notifWindowTimeout"];
        var mask = page.prefMap["mask"];
        console.log("stoandl-smoke: watch sections " + page.prefShape.map(function (g) { return g.title + (g.advanced ? "(collapsed)" : ""); }).join(", ")
                    + " · disabled " + gated.length + (gated.length ? " (" + gated[0] + ": " + page.prefMap[gated[0]].subtitle + ")" : "")
                    + (nwt ? " · notifWindowTimeout " + nwt.currentInt + " " + nwt.unit + " ×" + nwt.scale : "")
                    + (mask ? " · help mask: " + mask.helpText : ""));
        // Reset to defaults, against the mock only (a real daemon would reset the user's watch).
        if (StoandlClient.daemonVersion().indexOf("mock") === 0) {
            resetConfirm.accepted();
            console.log("stoandl-smoke: watch reset, qlUp now '" + page.prefMap["qlUp"].qlCurrentLabel + "'");
        }
        var ql = page.prefById("qlBack");
        if (ql)
            console.log("stoandl-smoke: quick launch qlBack='" + page.quickLabel(ql.current) + "' options="
                        + page.quickOptions(ql.current, ql.allowed).join("|"));
        // Press the qlBack row: the page's one picker opens on its options with the stored one checked;
        // picking that one writes it back unchanged (through the row's "Off" → "off" conversion).
        var qlRow = StableRows.findRow(page, "id", "qlBack");
        if (qlRow && qlRow.item) {
            qlRow.item.clicked();
            var pk = pickerLoader.item;
            console.log("stoandl-smoke: picker '" + pk.title + "' " + pk.options.length + " options, checked "
                        + pk.currentIndex + " '" + pk.options[pk.currentIndex] + "' visible=" + pk.visible);
            pk.pick(pk.currentIndex);
            console.log("stoandl-smoke: picker wrote qlBack back: '" + page.prefMap["qlBack"].qlCurrentLabel + "'");
        }
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

    // One option picker for every enum / quick-launch / colour row, built on first use.
    function pickOption(title, options, currentIndex, onPicked) {
        pickerLoader.active = true;
        pickerLoader.item.choose(title, options, currentIndex, onPicked);
    }

    // A number shown scaled (the notification timeout in seconds) goes back in the daemon's unit.
    function applyNumber(p, shown) { page.applyPref(p.id, String(shown * (p.scale || 1))); }

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
    // (dndWeekdaySchedule ↔ dndWeekdayScheduleEnabled; the daemon's `requires` says so), and the daemon
    // lists the schedules last. So each schedule row moves right under its switch.
    function prefById(id) {
        for (var i = 0; i < page.watchPrefs.length; ++i)
            if (page.watchPrefs[i].id === id)
                return page.watchPrefs[i];
        return null;
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

    Connections {
        target: StoandlClient
        function onDaemonUpChanged() { if (StoandlClient.daemonUp) page.reload(); }
    }

    Component.onCompleted: page.reload()

    actions: [
        Kirigami.Action {
            icon.name: "edit-reset-symbolic"
            text: "Reset to defaults"
            enabled: StoandlClient.daemonUp && page.watchPrefs.length > 0
            onTriggered: resetConfirm.open()
        }
    ]

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

        // One FormHeader + FormCard per section; "Advanced" after a toggle row, collapsed.
        Repeater {
            model: page.prefShape
            delegate: ColumnLayout {
                id: sectionItem
                required property var modelData
                required property int index
                readonly property bool shown: !modelData.advanced || page.advancedOpen
                Layout.fillWidth: true
                spacing: 0

                FormCard.FormCard {
                    visible: sectionItem.modelData.advanced
                             && (sectionItem.index === 0 || !page.prefShape[sectionItem.index - 1].advanced)
                    Layout.topMargin: page.hasNormal ? Kirigami.Units.largeSpacing : 0
                    FormCard.FormButtonDelegate {
                        text: page.advancedOpen ? "Hide advanced settings" : "Advanced settings (" + page.advancedCount + ")"
                        icon.name: "configure-symbolic"
                        trailingLogo.direction: page.advancedOpen ? Qt.UpArrow : Qt.DownArrow
                        onClicked: page.advancedOpen = !page.advancedOpen
                    }
                }

                FormCard.FormHeader {
                    visible: sectionItem.shown
                    title: sectionItem.modelData.title
                }

                FormCard.FormCard {
                    visible: sectionItem.shown
                    Repeater {
                        model: sectionItem.modelData.rows
                        // One Loader per pref. modelData is only {id, type}; the pref itself is looked up
                        // here, on the Loader, where `page` resolves (inside the inline Components it
                        // doesn't — gui/CLAUDE.md, "QML scope gotcha"), so the Components read only
                        // prefLoader.pref.*. They are defined INLINE so they resolve `prefLoader` (a
                        // Loader can't satisfy a required property on a page-scoped component).
                        //
                        // The first section's rows are built at once, with the page's data, so the
                        // screen the page opens on is complete in its first frame; the rest are built
                        // asynchronously below it (each holding a row's height until it is ready), so
                        // the ~50 rows don't block the push animation. A search hit builds them all at
                        // once, so its row's position is final; Advanced rows wait until it is opened.
                        delegate: Loader {
                            id: prefLoader
                            required property var modelData
                            readonly property var pref: page.prefMap[modelData.id] || ({})
                            Layout.fillWidth: true
                            Layout.preferredHeight: status === Loader.Ready || !active ? -1 : Kirigami.Units.gridUnit * 3
                            active: sectionItem.shown
                            asynchronous: sectionItem.index > 0 && page.focusId === ""
                            onLoaded: if (modelData.id === page.focusId) focusFlash.reveal(prefLoader)
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
                                FormSwitchRow {
                                    id: sw
                                    text: prefLoader.pref.name || ""
                                    description: prefLoader.pref.subtitle || ""
                                    help: prefLoader.pref.helpText || ""
                                    enabled: prefLoader.pref.enabled !== false
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

                            // enum and quick launch: the name and the stored value; a click opens the page's
                            // one OptionPicker. The row only shows what the daemon stored, so a refused pick
                            // leaves it as it was.
                            Component {
                                id: enumPref
                                FormOptionRow {
                                    text: prefLoader.pref.name || ""
                                    description: prefLoader.pref.subtitle || ""
                                    help: prefLoader.pref.helpText || ""
                                    enabled: prefLoader.pref.enabled !== false
                                    value: prefLoader.pref.current || ""
                                    onClicked: {
                                        var id = prefLoader.modelData.id;
                                        page.pickOption(text, prefLoader.pref.allowed, prefLoader.pref.optionIndex,
                                                        function (i, option) { page.applyPref(id, option); });
                                    }
                                }
                            }

                            Component {
                                id: quickPref
                                FormOptionRow {
                                    text: prefLoader.pref.name || ""
                                    description: prefLoader.pref.subtitle || ""
                                    help: prefLoader.pref.helpText || ""
                                    enabled: prefLoader.pref.enabled !== false
                                    value: prefLoader.pref.qlCurrentLabel || ""
                                    // "Off" → the daemon's "off" sentinel; an app name resolves to its uuid daemon-side.
                                    onClicked: {
                                        var id = prefLoader.modelData.id;
                                        page.pickOption(text, prefLoader.pref.qlOptions, prefLoader.pref.optionIndex,
                                                        function (i, option) { page.applyPref(id, option === "Off" ? "off" : option); });
                                    }
                                }
                            }

                            Component {
                                id: numberPref
                                FormSpinRow {
                                    label: prefLoader.pref.name || ""
                                    description: prefLoader.pref.subtitle || ""
                                    help: prefLoader.pref.helpText || ""
                                    enabled: prefLoader.pref.enabled !== false
                                    from: prefLoader.pref.min || 0
                                    to: prefLoader.pref.max || 0
                                    unit: prefLoader.pref.unit || ""
                                    value: prefLoader.pref.currentInt >= 0 ? prefLoader.pref.currentInt
                                                                           : (prefLoader.pref.min || 0)
                                    onCommit: (newValue) => page.applyNumber(prefLoader.pref, newValue)
                                }
                            }

                            // Color: a swatch of the current value + a preset picker (the daemon takes a
                            // preset name back, and the current value is a hex, so no preset is checked).
                            // FormColorDelegate is avoided — it calls i18ndc(), and this app deliberately
                            // links no KF6 C++ (no KLocalizedContext on the engine).
                            Component {
                                id: colorPref
                                FormOptionRow {
                                    text: prefLoader.pref.name || ""
                                    description: prefLoader.pref.subtitle || ""
                                    help: prefLoader.pref.helpText || ""
                                    enabled: prefLoader.pref.enabled !== false
                                    value: "Choose…"
                                    onClicked: {
                                        var id = prefLoader.modelData.id;
                                        page.pickOption(text, prefLoader.pref.colorPresetList, -1,
                                                        function (i, option) { page.applyPref(id, option); });
                                    }
                                    Rectangle {
                                        implicitWidth: Kirigami.Units.iconSizes.smallMedium
                                        implicitHeight: Kirigami.Units.iconSizes.smallMedium
                                        radius: height / 2
                                        color: Qt.color(prefLoader.pref.colorCss || "#000000")
                                        border.width: 1
                                        border.color: Kirigami.Theme.disabledTextColor
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
                                    description: prefLoader.pref.subtitle || "Daily hours, 24-hour clock"
                                    help: prefLoader.pref.helpText || ""
                                    enabled: prefLoader.pref.enabled !== false
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

    // The picker every option row opens (pickOption), built on first use.
    Loader {
        id: pickerLoader
        active: false
        sourceComponent: OptionPicker {}
    }

    FocusFlash {
        id: focusFlash
        flickable: page.flickable
    }

    Kirigami.PromptDialog {
        id: resetConfirm
        title: "Reset watch preferences"
        subtitle: "Set every watch preference back to its default? The watch gets them when it is next connected."
        standardButtons: QQC2.Dialog.Ok | QQC2.Dialog.Cancel
        onAccepted: page.resetAll()
    }
}
