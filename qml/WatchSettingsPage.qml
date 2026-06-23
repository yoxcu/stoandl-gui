import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// Watch "advanced settings" (the WatchPrefs BlobDB the official app exposes). The daemon's
// ListWatchPrefs sends one record per pref: id/type/current/default/allowed/flags/name/description,
// where type ∈ {bool, number, enum, quicklaunch, color}. We render ONE delegate per type — crucially,
// quicklaunch is an APP PICKER (not a slider setting a uuid) and enum/color get real combos/pickers —
// and group the ~46 prefs into labelled sections instead of one undifferentiated list.
Kirigami.ScrollablePage {
    id: page
    objectName: "watchSettings"
    title: "Watch settings"

    // [{id,type,current,currentBool,currentInt,default,allowed[],flags[],debug,name,description,(min,max,unit)}]
    property var watchPrefs: []
    // Launchable app titles for the quick-launch picker (locker watchapps; faces excluded).
    property var appTitles: []

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    // --- loaders -----------------------------------------------------------
    function reload() {
        if (!StoandlClient.daemonUp) { page.watchPrefs = []; page.appTitles = []; return; }
        page.watchPrefs = StoandlClient.listWatchPrefs();
        var titles = [];
        var apps = StoandlClient.listApps();
        for (var i = 0; i < apps.length; ++i)
            if (apps[i].type !== "watchface")
                titles.push(apps[i].title);
        page.appTitles = titles;
    }

    function applyPref(id, value) {
        var r = StoandlClient.setWatchPref(id, value);
        if (!r.ok)
            page.toast("Setting: " + (r.tail || r.kind));
        page.watchPrefs = StoandlClient.listWatchPrefs();   // re-fetch is authoritative
    }

    // --- quick-launch helpers ---------------------------------------------
    // "off" displays as "Off"; everything else (an app name, or a raw uuid for a system target) shows
    // verbatim. The option list is ["Off", …apps] plus the current value if it isn't already in it
    // (so a uuid target like the Quiet-Time toggle stays visible and selected).
    function quickLabel(current) {
        return (!current || String(current).toLowerCase() === "off") ? "Off" : current;
    }
    function quickOptions(current) {
        var opts = ["Off"].concat(page.appTitles);
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

    // --- grouping ----------------------------------------------------------
    // Ordered section rules, matched on the stable libpebble pref id. First match wins; anything
    // unmatched (a future libpebble pref) lands in "Other" so nothing is ever dropped.
    readonly property var sectionDefs: [
        { key: "quicklaunch", title: "Quick launch",        match: function (id) { return id.indexOf("ql") === 0; } },
        { key: "display",     title: "Display & backlight", match: function (id) { return id.indexOf("light") === 0 || id === "textStyle" || id === "displayOrientationLeftHanded" || id === "dynBacklightMinThreshold"; } },
        { key: "notif",       title: "Notifications",       match: function (id) { return id.indexOf("notif") === 0 || id === "mask" || id.indexOf("timelineQuickView") === 0; } },
        { key: "quiet",       title: "Quiet Time",          match: function (id) { return id.indexOf("dnd") === 0; } },
        { key: "vibe",        title: "Vibration",           match: function (id) { return id.indexOf("vibe") >= 0; } },
        { key: "music",       title: "Music",               match: function (id) { return id.indexOf("music") === 0; } },
        { key: "motion",      title: "Motion & menus",      match: function (id) { return id === "motionSensitivity" || id === "stationaryMode" || id.indexOf("menuScroll") === 0; } },
        { key: "clock",       title: "Clock & language",    match: function (id) { return id === "clock24h" || id === "timezoneSource" || id === "langEnglish"; } },
        { key: "other",       title: "Other",               match: function (id) { return true; } },
    ]

    // → [{title, prefs:[…]}] in sectionDefs order, dropping empty sections. Per-pref display data the
    // delegates need (quick-launch options, color presets/swatch) is precomputed HERE, in page scope —
    // a property *binding* inside the nested inline delegate components can't call a page method
    // (handlers can), so the delegates only read modelData.*.
    readonly property var sections: {
        var buckets = {};
        for (var i = 0; i < page.watchPrefs.length; ++i) {
            var p = page.watchPrefs[i];
            if (p.type === "quicklaunch") {
                p.qlOptions = page.quickOptions(p.current);
                p.qlCurrentLabel = page.quickLabel(p.current);
            } else if (p.type === "color") {
                p.colorPresetList = page.colorPresets(p.allowed);
                p.colorCss = page.colorHexCss(p.current);
            }
            for (var s = 0; s < page.sectionDefs.length; ++s) {
                if (page.sectionDefs[s].match(p.id)) {
                    var k = page.sectionDefs[s].key;
                    (buckets[k] || (buckets[k] = [])).push(p);
                    break;
                }
            }
        }
        var out = [];
        for (var d = 0; d < page.sectionDefs.length; ++d) {
            var rows = buckets[page.sectionDefs[d].key];
            if (rows && rows.length) out.push({ title: page.sectionDefs[d].title, prefs: rows });
        }
        return out;
    }

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

        // No watch connected (or no prefs synced yet).
        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.watchPrefs.length === 0
            Layout.topMargin: Kirigami.Units.largeSpacing
            FormCard.FormPlaceholderMessageDelegate {
                icon.name: "chronometer-symbolic"
                text: "No watch settings"
                explanation: "Connect a watch to read and change its settings."
            }
        }

        // One FormHeader + FormCard per non-empty section.
        Repeater {
            model: page.sections
            delegate: ColumnLayout {
                id: sectionItem
                required property var modelData
                Layout.fillWidth: true
                spacing: 0

                FormCard.FormHeader { title: sectionItem.modelData.title }

                FormCard.FormCard {
                    Repeater {
                        model: sectionItem.modelData.prefs
                        // One Loader per pref; the per-type delegate Components are defined INLINE so
                        // they resolve `modelData` from the Loader's required property (a Loader can't
                        // satisfy a required property on a page-scoped component at creation time).
                        delegate: Loader {
                            id: prefLoader
                            required property var modelData
                            Layout.fillWidth: true
                            sourceComponent: modelData.type === "bool" ? boolPref
                                           : modelData.type === "enum" ? enumPref
                                           : modelData.type === "quicklaunch" ? quickPref
                                           : modelData.type === "number" ? numberPref
                                           : modelData.type === "color" ? colorPref
                                           : fallbackPref

                            Component {
                                id: boolPref
                                FormCard.FormSwitchDelegate {
                                    text: prefLoader.modelData.name
                                    description: prefLoader.modelData.description
                                    checked: prefLoader.modelData.currentBool === true
                                    onToggled: page.applyPref(prefLoader.modelData.id, checked ? "true" : "false")
                                }
                            }

                            Component {
                                id: enumPref
                                FormCard.FormComboBoxDelegate {
                                    text: prefLoader.modelData.name
                                    description: prefLoader.modelData.description
                                    model: prefLoader.modelData.allowed
                                    // allowed + current are both display names, so indexOf matches.
                                    currentIndex: { var o = prefLoader.modelData.allowed || []; var i = o.indexOf(prefLoader.modelData.current); return i >= 0 ? i : 0; }
                                    onActivated: page.applyPref(prefLoader.modelData.id, currentValue)
                                }
                            }

                            Component {
                                id: quickPref
                                FormCard.FormComboBoxDelegate {
                                    text: prefLoader.modelData.name
                                    description: prefLoader.modelData.description
                                    model: prefLoader.modelData.qlOptions
                                    currentIndex: { var o = prefLoader.modelData.qlOptions || []; var i = o.indexOf(prefLoader.modelData.qlCurrentLabel); return i >= 0 ? i : 0; }
                                    // "Off" → the daemon's "off" sentinel; an app name resolves to its uuid daemon-side.
                                    onActivated: page.applyPref(prefLoader.modelData.id, currentText === "Off" ? "off" : currentText)
                                }
                            }

                            Component {
                                id: numberPref
                                FormCard.FormSpinBoxDelegate {
                                    id: sb
                                    // Guard: the spinbox fires onValueChanged on the programmatic initial
                                    // set too — only commit once the user moves it (ready flips in
                                    // Component.onCompleted, after the initial value is applied).
                                    property bool ready: false
                                    label: prefLoader.modelData.name
                                    from: prefLoader.modelData.min
                                    to: prefLoader.modelData.max
                                    // ~100 steps across the range so wide ms ranges stay navigable.
                                    stepSize: Math.max(1, Math.round((prefLoader.modelData.max - prefLoader.modelData.min) / 100))
                                    textFromValue: function (v, locale) { return v + (prefLoader.modelData.unit ? " " + prefLoader.modelData.unit : ""); }
                                    valueFromText: function (text, locale) { return parseInt(text, 10) || 0; }
                                    Component.onCompleted: {
                                        sb.value = prefLoader.modelData.currentInt >= 0 ? prefLoader.modelData.currentInt : prefLoader.modelData.min;
                                        sb.ready = true;
                                    }
                                    // onValueChanged fires on EVERY step/auto-repeat; applyPref re-fetches and
                                    // rebuilds the whole list (recreating this very control). So debounce: commit
                                    // once ~500 ms after the user stops, not per tick (avoids a write storm /
                                    // BlobDB sync per step, and recreating the focused control mid-interaction).
                                    onValueChanged: if (sb.ready) commitTimer.restart()
                                    Timer {
                                        id: commitTimer
                                        interval: 500
                                        repeat: false
                                        onTriggered: page.applyPref(prefLoader.modelData.id, String(sb.value))
                                    }
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
                                                text: prefLoader.modelData.name
                                                elide: Text.ElideRight
                                            }
                                            QQC2.Label {
                                                Layout.fillWidth: true
                                                visible: prefLoader.modelData.description !== ""
                                                text: prefLoader.modelData.description
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
                                            color: Qt.color(prefLoader.modelData.colorCss)
                                            border.width: 1
                                            border.color: Kirigami.Theme.disabledTextColor
                                        }
                                        QQC2.ComboBox {
                                            id: presetBox
                                            model: prefLoader.modelData.colorPresetList
                                            // current is a hex, not a preset name → no preselection.
                                            currentIndex: -1
                                            displayText: currentIndex < 0 ? "Choose…" : currentText
                                            onActivated: page.applyPref(prefLoader.modelData.id, currentText)
                                        }
                                    }
                                }
                            }

                            // Unknown/future type: a read-only row rather than a broken control.
                            Component {
                                id: fallbackPref
                                FormCard.FormTextDelegate {
                                    text: prefLoader.modelData.name
                                    description: prefLoader.modelData.current
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
