import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// Daemon configuration — the stoandl.conf keys the daemon exposes over D-Bus (GetConfigSchema /
// GetConfig / SetConfig). Schema-driven: each key declares a type (toggle | combo | text | int | list),
// the section to file it under, whether it applies live or needs a daemon restart, and — for numbers —
// its range and unit. New keys the daemon adds therefore appear here automatically, with the right
// widget, and nothing in this file names a config key.
Kirigami.ScrollablePage {
    id: page
    objectName: "generalSettings"
    title: "Daemon configuration"

    // [{key,type,label,options[],desc,group,restart,min,max,unit,placeholder}]
    property var cfgSchema: []
    property var cfgValues: ({})   // {key:value(string)}

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    function reload() {
        if (!StoandlClient.daemonUp) { page.cfgSchema = []; page.cfgValues = ({}); return; }
        page.cfgSchema = StoandlClient.configSchema();
        var c = StoandlClient.getConfig();
        page.cfgValues = (c && c.values) ? c.values : ({});
        if (StoandlClient.smokeMs > 0)
            console.log("stoandl-smoke: general loaded " + page.cfgSchema.length + " keys in " + page.groups.length + " groups");
    }

    function applyConfig(key, value) {
        var r = StoandlClient.setConfig(key, value);
        // The daemon validates (ranges, list shapes, values that would corrupt stoandl.conf) and answers
        // with the reason, so a rejected edit is explained rather than silently reverted by the re-fetch.
        if (!r.ok) page.toast("Config: " + (r.tail || r.kind));
        page.reload();
    }

    function currentValue(key) { return (page.cfgValues || {})[key] || ""; }

    // Schema rows bucketed into their declared sections, in first-seen order (the daemon emits the
    // fields in display order, so the sections come out ordered too).
    //
    // Each row carries its DISPLAY data precomputed (`value`, `valueInt`, `description`): a property
    // *binding* inside a nested inline Component resolves `page` to the QQmlComponent, not the page, so
    // a delegate must read only `modelData.*` and never call a page method (gui/CLAUDE.md, "QML scope
    // gotcha"). Handlers are fine, which is why applyConfig() is still called directly.
    readonly property var groups: {
        var order = [];
        var buckets = {};
        var values = page.cfgValues || {};
        for (var i = 0; i < page.cfgSchema.length; ++i) {
            var f = page.cfgSchema[i];
            var g = f.group || "Settings";
            var v = values[f.key] || "";
            var n = parseInt(v, 10);
            var row = {
                key: f.key, type: f.type, label: f.label, options: f.options,
                min: f.min, max: f.max, unit: f.unit, placeholder: f.placeholder,
                value: v,
                // Clamped into the schema's range so the spin box never starts outside its own bounds.
                valueInt: isNaN(n) ? f.min : Math.max(f.min, Math.min(f.max, n)),
                // The daemon marks keys it only reads at startup. Say so on the row itself — otherwise
                // flipping one looks exactly like a live change while doing nothing until a restart.
                description: f.restart ? (f.desc + " — takes effect after restarting stoandl") : f.desc,
            };
            if (!buckets[g]) { buckets[g] = []; order.push(g); }
            buckets[g].push(row);
        }
        var out = [];
        for (var j = 0; j < order.length; ++j) out.push({ title: order[j], fields: buckets[order[j]] });
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

        Kirigami.PlaceholderMessage {
            visible: StoandlClient.daemonUp && page.cfgSchema.length === 0
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
            icon.name: "settings-configure-symbolic"
            text: "No configuration"
            explanation: "The daemon exposes no editable configuration keys."
        }

        // One FormHeader + FormCard per section (same shape as WatchSettingsPage's pref sections).
        Repeater {
            model: page.groups
            delegate: ColumnLayout {
                id: groupItem
                required property var modelData
                Layout.fillWidth: true
                spacing: 0

                FormCard.FormHeader { title: groupItem.modelData.title }

                FormCard.FormCard {
                    Repeater {
                        model: groupItem.modelData.fields
                        // One Loader per key; the per-type Components are defined INLINE so they resolve
                        // `modelData` off the Loader's required property (a Loader cannot satisfy a
                        // required property on a page-scoped Component at creation time).
                        delegate: Loader {
                            id: cfgLoader
                            required property var modelData
                            Layout.fillWidth: true
                            sourceComponent: modelData.type === "toggle" ? cfgToggle
                                           : modelData.type === "combo"  ? cfgCombo
                                           : modelData.type === "int"    ? cfgInt
                                           : cfgText   // text, list, and any future kind

                            Component {
                                id: cfgToggle
                                FormCard.FormSwitchDelegate {
                                    text: cfgLoader.modelData.label
                                    description: cfgLoader.modelData.description
                                    checked: cfgLoader.modelData.value === "true"
                                    onToggled: page.applyConfig(cfgLoader.modelData.key, checked ? "true" : "false")
                                }
                            }

                            Component {
                                id: cfgCombo
                                FormCard.FormComboBoxDelegate {
                                    text: cfgLoader.modelData.label
                                    description: cfgLoader.modelData.description
                                    model: cfgLoader.modelData.options
                                    currentIndex: {
                                        var o = cfgLoader.modelData.options || [];
                                        var i = o.indexOf(cfgLoader.modelData.value);
                                        return i >= 0 ? i : 0;
                                    }
                                    onActivated: page.applyConfig(cfgLoader.modelData.key, currentValue)
                                }
                            }

                            // Number: a spin box bounded by the schema's min/max, with the unit rendered
                            // into the display text. FormSpinBoxDelegate has no `description`, so the
                            // label/description column is built by hand (as WatchSettingsPage's colour
                            // row does) to keep the density identical to the switch/combo rows.
                            Component {
                                id: cfgInt
                                FormCard.AbstractFormDelegate {
                                    background: null
                                    contentItem: RowLayout {
                                        spacing: Kirigami.Units.largeSpacing
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 0
                                            QQC2.Label {
                                                Layout.fillWidth: true
                                                text: cfgLoader.modelData.label
                                                elide: Text.ElideRight
                                            }
                                            QQC2.Label {
                                                Layout.fillWidth: true
                                                visible: text !== ""
                                                text: cfgLoader.modelData.description
                                                wrapMode: Text.WordWrap
                                                font: Kirigami.Theme.smallFont
                                                color: Kirigami.Theme.disabledTextColor
                                            }
                                        }
                                        QQC2.SpinBox {
                                            id: sb
                                            // The spin box fires valueChanged on the programmatic initial
                                            // set too; only commit once the user has moved it.
                                            property bool ready: false
                                            Layout.alignment: Qt.AlignVCenter
                                            from: cfgLoader.modelData.min
                                            to: cfgLoader.modelData.max
                                            editable: true
                                            // ~100 steps across the range so a wide one stays navigable.
                                            stepSize: Math.max(1, Math.round((cfgLoader.modelData.max - cfgLoader.modelData.min) / 100))
                                            textFromValue: function (v, locale) {
                                                return v + (cfgLoader.modelData.unit ? " " + cfgLoader.modelData.unit : "");
                                            }
                                            valueFromText: function (text, locale) { return parseInt(text, 10) || 0; }
                                            Component.onCompleted: {
                                                sb.value = cfgLoader.modelData.valueInt;
                                                sb.ready = true;
                                            }
                                            // valueChanged fires on every step/auto-repeat, and applyConfig
                                            // re-fetches and rebuilds this very control — so commit once
                                            // ~500 ms after the user stops, not per tick.
                                            onValueChanged: if (sb.ready) commitTimer.restart()
                                            Timer {
                                                id: commitTimer
                                                interval: 500
                                                repeat: false
                                                onTriggered: page.applyConfig(cfgLoader.modelData.key, String(sb.value))
                                            }
                                        }
                                    }
                                }
                            }

                            // Text and list (comma-separated), via the shared FormTextRow (which exists
                            // because FormTextFieldDelegate has no `description` and calls i18ndc()).
                            // The schema's placeholder documents the expected shape (e.g. Name:lat:lon).
                            Component {
                                id: cfgText
                                FormTextRow {
                                    id: tf
                                    label: cfgLoader.modelData.label
                                    description: cfgLoader.modelData.description
                                    value: cfgLoader.modelData.value
                                    placeholderText: cfgLoader.modelData.placeholder
                                    // Commit on focus-out / Enter only: applyConfig rebuilds this
                                    // control, so committing per keystroke would fight the user.
                                    onEditingFinished: {
                                        if (tf.value !== cfgLoader.modelData.value)
                                            page.applyConfig(cfgLoader.modelData.key, tf.value);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        FormCard.FormSectionText {
            visible: StoandlClient.daemonUp && page.cfgSchema.length > 0
            text: "These settings render the daemon's stoandl.conf. New keys exposed by the daemon appear here automatically. Changes apply live unless the row says otherwise."
        }
    }
}
