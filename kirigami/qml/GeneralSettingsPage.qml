import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui
import "ConfList.js" as ConfList
import "StableRows.js" as StableRows

// Daemon configuration — the stoandl.conf keys the daemon exposes over D-Bus (GetConfigSchema /
// GetConfig / SetConfig). Schema-driven: each key declares a type (toggle | combo | text | int | list),
// the section to file it under, whether it applies live or needs a daemon restart, and — for numbers —
// its range and unit. New keys the daemon adds therefore appear here automatically, with the right
// widget, and nothing in this file names a config key. The additions are the Voice section's model
// manager (VoiceModelsCard) and the Weather section's city search (WeatherSearchCard), each shown under
// that section's keys.
Kirigami.ScrollablePage {
    id: page
    objectName: "generalSettings"
    title: "Daemon configuration"

    // The page holds three things, each reassigned only when it really changed:
    //  - cfgShape: [{title, rows:[{key,type}]}], the sections in first-seen order (the daemon emits the
    //    fields in display order). It is the ONLY thing the Repeaters see, so rows are created once per
    //    shape: opening the page builds each row once, and an edit or a re-read builds nothing.
    //  - cfgFields: key → {label, description, options[], min, max, unit, placeholder}. An entry keeps
    //    its identity while the daemon reports it unchanged (StableRows.reuse), so only a row whose
    //    schema moved (the installed-model dropdown after a download) re-evaluates.
    //  - cfgValues: key → value string (GetConfig).
    // Each row looks its field and value up by key on its Loader; see the delegate below.
    property var cfgShape: []
    property var cfgFields: ({})
    property var cfgValues: ({})
    // Bumped by every edit (applyConfig). A reload() fetch that started before an edit answers after
    // the edit's synchronous re-read, with values read before the set: it then keeps cfgValues.
    property int editSeq: 0

    readonly property var groupTitles: page.cfgShape.map(function (g) { return g.title; })

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    // Schema + values: on open, when the daemon comes back, and after the Voice card changes the
    // installed models (the one schema change an edit on this page can cause). Asynchronous; an edit
    // re-reads the values synchronously instead (reloadValues), so its handler can re-assert at once.
    function reload() {
        if (!StoandlClient.daemonUp) { page.applyAll([], {}); return; }
        var edits = page.editSeq;
        StoandlClient.fetch(page, [["configSchema"], ["getConfig"]], function (r) {
            var schema = r[0];
            var values = edits !== page.editSeq ? page.cfgValues   // an edit re-read since: newer
                       : (r[1] && r[1].values) ? r[1].values : {};
            page.applyAll(schema, values);
            if (StoandlClient.smokeMs > 0)
                console.log("stoandl-smoke: general loaded " + schema.length + " keys in " + page.cfgShape.length + " groups");
        });
    }

    // Values only: after a set. The re-read is still authoritative (the daemon answers with its
    // normalised value), but it touches nothing but the rows whose value changed.
    function reloadValues() {
        var c = StoandlClient.daemonUp ? StoandlClient.getConfig() : null;
        page.applyValues((c && c.values) ? c.values : {});
    }

    function applyValues(values) {
        var v = {};
        for (var k in values) v[k] = String(values[k]);
        if (!StableRows.same(page.cfgValues, v)) page.cfgValues = v;
    }

    function applyAll(schema, values) {
        var order = [];
        var buckets = {};
        var fields = {};
        for (var i = 0; i < schema.length; ++i) {
            var f = schema[i];
            var g = f.group || "Settings";
            fields[f.key] = {
                label: f.label, options: f.options, min: f.min, max: f.max, unit: f.unit,
                placeholder: f.placeholder,
                // The daemon marks keys it only reads at startup. Say so on the row itself — otherwise
                // flipping one looks exactly like a live change while doing nothing until a restart.
                description: f.restart ? (f.desc + " — takes effect after restarting stoandl") : f.desc,
            };
            if (!buckets[g]) { buckets[g] = []; order.push(g); }
            buckets[g].push({ key: f.key, type: f.type });
        }
        var shape = order.map(function (t) { return { title: t, rows: buckets[t] }; });
        // Values and fields before the shape, so a row created by a new shape finds its data in place.
        page.applyValues(values);
        var nf = StableRows.reuse(page.cfgFields, fields);
        if (nf !== page.cfgFields) page.cfgFields = nf;
        if (!StableRows.same(page.cfgShape, shape)) {
            page.parkCards();
            page.cfgShape = shape;
        }
    }

    function applyConfig(key, value) {
        page.editSeq++;
        var r = StoandlClient.setConfig(key, value);
        // The daemon validates (ranges, list shapes, values that would corrupt stoandl.conf) and answers
        // with the reason, so a rejected edit is explained; the re-read then shows the stored value.
        if (!r.ok) page.toast("Config: " + (r.tail || r.kind));
        page.reloadValues();
    }

    // The Voice and Weather cards are created once, at page level, and moved under their section's
    // keys (the group delegate's cardSlot) when that section exists. They live outside the section
    // Repeater so a new shape never recreates them or repeats their D-Bus calls; a shape change parks
    // them first, so they are never children of a delegate being destroyed.
    function placeCards(groupItem) {
        if (groupItem.groupTitle === "Voice") voiceCard.parent = groupItem.cardSlot;
        if (groupItem.groupTitle === "Weather") weatherCard.parent = groupItem.cardSlot;
    }
    function parkCards() {
        voiceCard.parent = cardPark;
        weatherCard.parent = cardPark;
    }

    // Smoke hook (SettingsPage drives it): the city search's D-Bus round trip and record parsing,
    // read-only — it adds nothing, and a daemon with weather.place_search off answers disabled:.
    function smokeExercise() {
        // The two cards sit under their own section, created once, and the city search follows the
        // page's weather.place_search instead of reading the config itself.
        console.log("stoandl-smoke: general cards voice=" + (voiceCard.parent !== cardPark ? "placed" : "parked")
            + " weather=" + (weatherCard.parent !== cardPark ? "placed" : "parked")
            + " searchOn=" + (weatherCard.item ? weatherCard.item.searchOn : "none"));
        var r = StoandlClient.searchWeatherPlace("Berlin");
        var p = (r.places || [])[0];
        console.log("stoandl-smoke: weather search " + r.kind + ", " + (r.places || []).length + " places"
            + (p ? " (first " + p.name + " " + p.lat + "," + p.lon + ")" : ""));
        // The list codec must match the daemon's ConfList.kt: commas inside an item survive a round trip
        // and a plain (pre-escaping) list still splits on its commas.
        var items = ["Sure, see you", "C:\\x\\", "Ok"];
        var enc = ConfList.encode(items);
        var same = JSON.stringify(ConfList.decode(enc)) === JSON.stringify(items)
            && JSON.stringify(ConfList.decode(" Ok, Yes ,,C:\\p")) === JSON.stringify(["Ok", "Yes", "C:\\p"]);
        console.log("stoandl-smoke: list codec " + (same ? "ok" : "MISMATCH") + " (" + enc + ")");
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
            visible: StoandlClient.daemonUp && page.cfgShape.length === 0
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
            icon.name: "settings-configure-symbolic"
            text: "No configuration"
            explanation: "The daemon exposes no editable configuration keys."
        }

        // One FormHeader + FormCard per section (same shape as WatchSettingsPage's pref sections).
        Repeater {
            model: page.cfgShape
            onItemAdded: (index, item) => page.placeCards(item)
            delegate: ColumnLayout {
                id: groupItem
                required property var modelData
                readonly property string groupTitle: modelData.title
                property alias cardSlot: cardSlot
                Layout.fillWidth: true
                spacing: 0

                FormCard.FormHeader { title: groupItem.modelData.title }

                FormCard.FormCard {
                    Repeater {
                        model: groupItem.modelData.rows
                        // One Loader per key. modelData is only {key, type}; the row's schema and value
                        // are looked up here, on the Loader, where `page` resolves (inside the inline
                        // Components it doesn't — gui/CLAUDE.md, "QML scope gotcha"), so the Components
                        // read only cfgLoader.*. They are defined INLINE so they resolve `cfgLoader` (a
                        // Loader cannot satisfy a required property on a page-scoped Component).
                        //
                        // Rows are built asynchronously (opening the page no longer blocks on ~80 rows)
                        // and hold a row's height until they are ready, so the page doesn't jump.
                        delegate: Loader {
                            id: cfgLoader
                            required property var modelData
                            readonly property var field: page.cfgFields[modelData.key] || ({})
                            readonly property string value: page.cfgValues[modelData.key] || ""
                            // Clamped into the schema's range so the spin box never starts outside its bounds.
                            readonly property int valueInt: {
                                var n = parseInt(cfgLoader.value, 10);
                                var lo = cfgLoader.field.min || 0, hi = cfgLoader.field.max || 0;
                                return isNaN(n) ? lo : Math.max(lo, Math.min(hi, n));
                            }
                            readonly property int optionIndex: {
                                var i = (cfgLoader.field.options || []).indexOf(cfgLoader.value);
                                return i >= 0 ? i : 0;
                            }
                            Layout.fillWidth: true
                            Layout.preferredHeight: status === Loader.Ready ? -1 : Kirigami.Units.gridUnit * 3
                            asynchronous: true
                            sourceComponent: modelData.type === "toggle" ? cfgToggle
                                           : modelData.type === "combo"  ? cfgCombo
                                           : modelData.type === "int"    ? cfgInt
                                           : modelData.type === "secret" ? cfgSecret
                                           : modelData.type === "list"   ? cfgList
                                           : cfgText   // text and any future kind

                            // The rows outlive an edit now, so each handler puts its control back on the
                            // re-read value: a value the daemon refused (unchanged, so no binding fires)
                            // would otherwise stay on screen as if it had been stored.
                            Component {
                                id: cfgToggle
                                FormCard.FormSwitchDelegate {
                                    id: sw
                                    text: cfgLoader.field.label || ""
                                    description: cfgLoader.field.description || ""
                                    // Only the initial value: FormSwitchDelegate assigns `checked` from its
                                    // inner Switch, which drops any binding, so it follows by hand.
                                    checked: cfgLoader.value === "true"
                                    Connections {
                                        target: cfgLoader
                                        function onValueChanged() { sw.checked = cfgLoader.value === "true"; }
                                    }
                                    onToggled: {
                                        page.applyConfig(cfgLoader.modelData.key, sw.checked ? "true" : "false");
                                        sw.checked = cfgLoader.value === "true";
                                    }
                                }
                            }

                            Component {
                                id: cfgCombo
                                FormCard.FormComboBoxDelegate {
                                    text: cfgLoader.field.label || ""
                                    description: cfgLoader.field.description || ""
                                    model: cfgLoader.field.options
                                    currentIndex: cfgLoader.optionIndex
                                    onActivated: {
                                        page.applyConfig(cfgLoader.modelData.key, currentValue);
                                        currentIndex = Qt.binding(function () { return cfgLoader.optionIndex; });
                                    }
                                }
                            }

                            // Number: the shared FormSpinRow (bounded, unit in the display text, a
                            // debounced commit, and it follows the re-read value between edits).
                            Component {
                                id: cfgInt
                                FormSpinRow {
                                    label: cfgLoader.field.label || ""
                                    description: cfgLoader.field.description || ""
                                    from: cfgLoader.field.min || 0
                                    to: cfgLoader.field.max || 0
                                    unit: cfgLoader.field.unit || ""
                                    value: cfgLoader.valueInt
                                    onCommit: (newValue) => page.applyConfig(cfgLoader.modelData.key, String(newValue))
                                }
                            }

                            // A secret (an API key): the daemon keeps it in the keyring and reports only
                            // "set" or empty, so the field starts blank, shows dots, and an empty commit
                            // leaves the stored value alone ("Remove" clears it).
                            Component {
                                id: cfgSecret
                                ColumnLayout {
                                    spacing: 0
                                    FormTextRow {
                                        id: sf
                                        label: cfgLoader.field.label || ""
                                        description: (cfgLoader.field.description || "") +
                                            (cfgLoader.value === "set" ? " (stored)" : " (not set)")
                                        echoMode: TextInput.Password
                                        placeholderText: cfgLoader.value === "set" ? "••••••••" : ""
                                        onEditingFinished: {
                                            if (sf.value !== "") {
                                                page.applyConfig(cfgLoader.modelData.key, sf.value);
                                                sf.value = "";   // never kept on screen, stored or not
                                            }
                                        }
                                    }
                                    FormCard.FormButtonDelegate {
                                        visible: cfgLoader.value === "set"
                                        text: "Remove " + (cfgLoader.field.label || "")
                                        onClicked: page.applyConfig(cfgLoader.modelData.key, "")
                                    }
                                }
                            }

                            // A list: one row per item (add, remove, reorder); items may contain commas.
                            Component {
                                id: cfgList
                                FormListRow {
                                    label: cfgLoader.field.label || ""
                                    description: cfgLoader.field.description || ""
                                    value: cfgLoader.value
                                    placeholderText: cfgLoader.field.placeholder || ""
                                    onCommit: (newValue) => page.applyConfig(cfgLoader.modelData.key, newValue)
                                }
                            }

                            // Text, via the shared FormTextRow (which exists because FormTextFieldDelegate
                            // has no `description` and calls i18ndc()). The schema's placeholder documents
                            // the expected shape.
                            Component {
                                id: cfgText
                                FormTextRow {
                                    id: tf
                                    label: cfgLoader.field.label || ""
                                    description: cfgLoader.field.description || ""
                                    value: cfgLoader.value
                                    placeholderText: cfgLoader.field.placeholder || ""
                                    // Commit on focus-out / Enter only: committing per keystroke would
                                    // write a half-typed value on every key.
                                    onEditingFinished: {
                                        if (tf.value !== cfgLoader.value) {
                                            page.applyConfig(cfgLoader.modelData.key, tf.value);
                                            tf.value = Qt.binding(function () { return cfgLoader.value; });
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // The Voice / Weather card moves in here (placeCards); empty for every other section.
                ColumnLayout {
                    id: cardSlot
                    Layout.fillWidth: true
                    spacing: 0
                }
            }
        }

        // Where the two cards wait while their section is absent or being rebuilt (invisible, so the
        // layout skips it).
        Item {
            id: cardPark
            visible: false

            // Downloads and removes speech models; its changed() re-reads schema and config so the
            // installed-model dropdown and the backend follow a finished download.
            Loader {
                id: voiceCard
                Layout.fillWidth: true
                active: page.groupTitles.indexOf("Voice") >= 0
                sourceComponent: VoiceModelsCard { onChanged: page.reload() }
            }

            // City search: adds a found place to weather.locations, then re-reads the config.
            Loader {
                id: weatherCard
                Layout.fillWidth: true
                active: page.groupTitles.indexOf("Weather") >= 0
                sourceComponent: WeatherSearchCard {
                    searchOn: page.cfgValues["weather.place_search"] === "true"
                    onChanged: page.reloadValues()
                }
            }
        }

        FormCard.FormSectionText {
            visible: StoandlClient.daemonUp && page.cfgShape.length > 0
            text: "These settings render the daemon's stoandl.conf. New keys exposed by the daemon appear here automatically. Changes apply live unless the row says otherwise."
        }
    }
}
