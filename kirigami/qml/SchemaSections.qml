import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui
import "ConfList.js" as ConfList
import "StableRows.js" as StableRows

// The stoandl.conf keys of one Settings page (the schema's `page` column), schema-driven: GetConfigSchema
// declares each key's type (toggle | combo | text | int | list | secret), its section (`group`), whether
// it applies live or after a restart, its range, help, the keys it depends on (`requires`), its default
// and the hosts it contacts (`egress`). A new daemon key appears on its page with the right widget, and
// nothing here names a key except the anchors below, which put a card or a link after one.
//
// Sections titled "Advanced …" (a page's last) start collapsed behind one "Advanced settings (N)" row,
// and their rows aren't built until it is opened. A row whose `requires` doesn't hold is locked (its value
// can't be changed, its help still opens) and says what it is used with; a row's (?) holds its help and a
// generated line: the default, the hosts it contacts, whether it waits for a restart, and its stoandl.conf
// key.
//
// SchemaSettingsPage shows one of these per page; DebugSettingsPage puts the Developer page's on top.
ColumnLayout {
    id: page
    spacing: 0

    /** The schema page to show. */
    property string pageName: ""
    /** A key to scroll to and highlight once its row is built (the Settings search); "" = none. */
    property string focusKey: ""
    /** The scrolling page's Flickable, for focusKey. */
    property Flickable flickable: null

    // The page holds these, each reassigned only when it really changed (StableRows), so opening the page
    // builds each row once and an edit or a re-read builds nothing:
    //  - cfgShape: [{title, advanced, rows:[{key,type}]}], the sections in the daemon's order with the
    //    "Advanced …" ones last. The ONLY thing the Repeaters see. A row of type "@preview" or "@link" is an
    //    anchor (rowAnchors) after the key it names in `anchor`.
    //  - cfgFields: key → what doesn't change with the values: label, help, options, range, requires.
    //  - cfgValues: key → value string (GetConfig).
    //  - cfgRows: key → {description, enabled}: the description with the restart note, the sync status of a
    //    service's master row and why the row is off; recomputed from the three above.
    // Each row looks its entries up by key on its Loader; see the delegate below.
    property var cfgShape: []
    property var cfgFields: ({})
    property var cfgValues: ({})
    property var cfgRows: ({})
    // Every key of the schema (all pages): {label, type}, for the requires notes and the restart message.
    property var keyInfo: ({})
    // GetSyncStatus by its key column, and MusicStatus for the Music master's subtitle.
    property var syncByKey: ({})
    property var music: ({})
    // Bumped by every edit (applyConfig). A reload() fetch that started before an edit answers after the
    // edit's synchronous re-read, with values read before the set: it then keeps cfgValues.
    property int editSeq: 0
    property bool advancedOpen: false
    property bool loadedOnce: false

    readonly property int advancedCount: page.cfgShape.reduce(function (n, g) {
        return n + (g.advanced ? g.rows.filter(function (r) { return r.type.charAt(0) !== "@"; }).length : 0);
    }, 0)
    readonly property bool hasNormal: page.cfgShape.some(function (g) { return !g.advanced; })

    // What follows a key on this page. A card (its own header and FormCard) goes under the section that
    // holds its key; an anchor row goes into that section's FormCard, right after the key's row.
    readonly property var cardAnchors: ({ "voice.local_model": "stt", "tts.local_voice": "tts", "weather.place_search": "weather" })
    readonly property var rowAnchors: ({
        "notification.app_name": { type: "@preview" },
        "calendar.discover": { type: "@link", target: "calendars", text: "Accounts and feeds",
                               description: "CalDAV accounts, iCal links and which calendars sync",
                               icon: "view-calendar-symbolic" },
        "health.sync": { type: "@link", target: "healthProfile", text: "Health profile",
                         description: "Height, weight, units and heart-rate tracking on the watch",
                         icon: "stoandl-heart-symbolic" }
    })

    Component { id: calendarsPageComp; CalendarsSettingsPage {} }
    Component { id: healthProfilePageComp; HealthProfileSettingsPage {} }

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    function openTarget(target) {
        applicationWindow().pushPage(target === "calendars" ? calendarsPageComp : healthProfilePageComp);
    }

    // Schema, values and sync status: on open, when the daemon comes back and on ConfigChanged
    // (debounced). Asynchronous; an edit re-reads the values synchronously instead (reloadValues), so its
    // handler can put its control back at once.
    function reload() {
        if (!StoandlClient.daemonUp) { page.applyAll([], {}); return; }
        var edits = page.editSeq;
        StoandlClient.fetch(page, [["configSchema"], ["getConfig"], ["getSyncStatus"]], function (r) {
            var values = edits !== page.editSeq ? page.cfgValues   // an edit re-read since: newer
                       : (r[1] && r[1].values) ? r[1].values : {};
            page.applySync(r[2] || []);
            page.applyAll(r[0] || [], values);
            page.loadedOnce = true;
            // The Music master's subtitle is what plays: one more read, only where that row is.
            var musicKey = page.serviceKey("music");
            if (musicKey !== "" && page.cfgFields[musicKey])
                StoandlClient.fetch(musicFetcher, ["musicStatus"], function (m) {
                    page.music = m || {};
                    page.updateRows();
                });
            if (StoandlClient.smokeMs > 0)
                console.log("stoandl-smoke: schema page '" + page.pageName + "' " + Object.keys(page.cfgFields).length
                            + " keys in " + page.cfgShape.length + " sections, " + page.advancedCount + " advanced");
        });
    }
    // A second fetch owner, so the music read doesn't drop the page's own (latest wins per owner).
    QtObject { id: musicFetcher }

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
        page.updateRows();
    }

    function applySync(rows) {
        var m = {};
        for (var i = 0; i < rows.length; ++i)
            if (rows[i].key) m[rows[i].key] = rows[i];
        if (!StableRows.same(page.syncByKey, m)) page.syncByKey = m;
    }
    function serviceKey(service) {
        for (var k in page.syncByKey)
            if (page.syncByKey[k].service === service) return k;
        return "";
    }

    function applyAll(schema, values) {
        var order = [];
        var buckets = {};
        var fields = {};
        var info = {};
        for (var i = 0; i < schema.length; ++i) {
            var f = schema[i];
            info[f.key] = { label: f.label, type: f.type };
            if (f.page !== page.pageName)
                continue;
            var g = f.group || "Settings";
            fields[f.key] = {
                label: f.label, type: f.type, options: f.options, min: f.min, max: f.max, unit: f.unit,
                placeholder: f.placeholder, requires: f.requires,
                // A key the daemon reads only at startup says so; the (?) says how.
                description: f.desc + (f.restart ? " (after restart)" : ""),
                help: page.helpText(f),
            };
            if (!buckets[g]) { buckets[g] = []; order.push(g); }
            buckets[g].push({ key: f.key, type: f.type });
            var a = page.rowAnchors[f.key];
            if (a)
                buckets[g].push({ key: f.key + a.type, type: a.type, anchor: f.key });
        }
        var sections = order.map(function (t) { return { title: t, advanced: t.indexOf("Advanced") === 0, rows: buckets[t] }; });
        var shape = sections.filter(function (s) { return !s.advanced; })
                            .concat(sections.filter(function (s) { return s.advanced; }));
        if (!StableRows.same(page.keyInfo, info)) page.keyInfo = info;
        // Values and fields before the shape, so a row created by a new shape finds its data in place.
        var nf = StableRows.reuse(page.cfgFields, fields);
        if (nf !== page.cfgFields) page.cfgFields = nf;
        page.applyValues(values);
        if (!StableRows.same(page.cfgShape, shape)) {
            page.parkCards();
            // A search hit in an Advanced section opens it.
            if (page.focusKey !== "" && shape.some(function (s) {
                    return s.advanced && s.rows.some(function (r) { return r.key === page.focusKey; }); }))
                page.advancedOpen = true;
            page.cfgShape = shape;
        }
    }

    // --- row texts -------------------------------------------------------------------------------
    // The (?) text: the key's help, then what the schema says about it in one generated line.
    function helpText(f) {
        var parts = [];
        if (f.help) parts.push(f.help);
        var d = page.valueText(f.default, f.type, f.unit);
        if (d !== "" && f.type !== "secret") parts.push("Default: " + d + ".");
        if (f.egress) parts.push("Contacts " + f.egress + ".");
        if (f.restart) parts.push("Applies after restarting stoandl.");
        parts.push((f.type === "secret" ? "Key (kept in the keyring): " : "stoandl.conf key: ") + f.key + ".");
        return parts.join(" ");
    }
    // A value as a row would show it: a toggle as on/off, a number with its unit, a list as its items.
    function valueText(v, type, unit) {
        if (v === undefined || v === "") return "";
        if (type === "toggle") return v === "true" ? "on" : v === "false" ? "off" : v;
        if (type === "int") return v + (unit ? " " + unit : "");
        if (type === "list") return ConfList.decode(v).join(", ");
        return v;
    }
    // Whether a row's `requires` holds: any alternative (key=value, or key!=value when negated); a key this
    // daemon doesn't list can't be checked and doesn't hold the row back.
    function requiresMet(reqs) {
        if (!reqs || reqs.length === 0) return true;
        return reqs.some(function (a) {
            var v = page.cfgValues[a.key];
            return v === undefined || ((v === a.value) !== a.negate);
        });
    }
    function usedWhen(reqs) {
        return "Used when " + reqs.map(function (a) {
            var k = page.keyInfo[a.key] || { label: a.key, type: "" };
            return "“" + k.label + "” " + (a.negate ? "isn't " : "is ") + page.valueText(a.value, k.type, "");
        }).join(" or ");
    }
    // A service master's state (GetSyncStatus): when it last synced, or what plays for Music.
    function statusText(key) {
        var s = page.syncByKey[key];
        if (!s) return "";
        // Weather and calendar are "unavailable" until they have something to read ("no source"), which
        // the rows right under their master fix; anything else (dnd's "no backend") is really missing.
        if (!s.available)
            return s.lastSync !== "no source" ? "Not available here"
                 : s.service === "weather" ? "No place yet"
                 : s.service === "calendar" ? "No calendar source yet" : "Nothing to sync yet";
        if (s.service === "music" && page.music && page.music.ok) {
            if (page.music.playing)
                return page.music.track ? "Now playing · " + page.music.track : "Playing · " + page.music.player;
            return page.music.track ? "Paused · " + page.music.track : "";
        }
        var last = s.lastSync || "";
        return s.enabled && (page.keyInfo[key] || {}).type === "toggle" && last !== "" && last !== "live" && last !== "off"
            ? "Last sync · " + last : "";
    }
    function updateRows() {
        var rows = {};
        for (var key in page.cfgFields) {
            var f = page.cfgFields[key];
            var met = page.requiresMet(f.requires);
            var status = page.statusText(key);
            rows[key] = {
                enabled: met,
                description: f.description + (status !== "" ? " · " + status : "")
                             + (met ? "" : " · " + page.usedWhen(f.requires)),
            };
        }
        var nr = StableRows.reuse(page.cfgRows, rows);
        if (nr !== page.cfgRows) page.cfgRows = nr;
    }

    // One option picker for every combo row, built on first use.
    function pickOption(title, options, currentIndex, onPicked) {
        pickerLoader.active = true;
        pickerLoader.item.choose(title, options, currentIndex, onPicked);
    }

    function applyConfig(key, value) {
        page.editSeq++;
        var r = StoandlClient.setConfig(key, value);
        // The daemon validates (ranges, list shapes, values that would corrupt stoandl.conf) and answers
        // with the reason, so a rejected edit is explained; the re-read then shows the stored value.
        if (!r.ok) page.toast((page.keyInfo[key] || { label: key }).label + ": " + (r.tail || r.kind));
        page.reloadValues();
        // A service's master row shows its sync state.
        if (page.syncByKey[key])
            page.applySync(StoandlClient.getSyncStatus());
        page.updateRows();
    }

    // --- cards -----------------------------------------------------------------------------------
    // The cards are created once, at this level, and moved under the section holding their anchor key (the
    // section delegate's cardSlot). They live outside the section Repeater so a new shape never recreates
    // them or repeats their D-Bus calls; a shape change parks them first, so they are never children of a
    // delegate being destroyed.
    function cardFor(kind) {
        return kind === "stt" ? sttCard : kind === "tts" ? ttsCard : weatherCard;
    }
    function placeCards(section) {
        section.modelData.rows.forEach(function (r) {
            var kind = page.cardAnchors[r.key];
            if (kind) page.cardFor(kind).parent = section.cardSlot;
        });
    }
    function parkCards() {
        sttCard.parent = cardPark;
        ttsCard.parent = cardPark;
        weatherCard.parent = cardPark;
    }

    // Smoke hook (SchemaSettingsPage drives it): the anchors and cards in place, the help of the first
    // row that has one (opened as a long press does), the requires gating, a combo's picker written back
    // unchanged; on the Weather page a read-only city search.
    function smokeExercise() {
        var placed = [];
        [["stt", sttCard], ["tts", ttsCard], ["weather", weatherCard]].forEach(function (c) {
            if (c[1].active) placed.push(c[0] + "=" + (c[1].parent !== cardPark ? "placed" : "parked"));
        });
        var anchorKeys = [];
        page.cfgShape.forEach(function (g) {
            g.rows.forEach(function (r) { if (r.type.charAt(0) === "@") anchorKeys.push(r.key); });
        });
        var off = Object.keys(page.cfgRows).filter(function (k) { return !page.cfgRows[k].enabled; });
        console.log("stoandl-smoke: page '" + page.pageName + "' cards " + (placed.join(" ") || "none")
                    + " anchors " + (anchorKeys.join(",") || "none") + " · disabled " + off.length
                    + (off.length ? " (" + off[0] + ": " + page.cfgRows[off[0]].description + ")" : ""));
        // The first row's (?): its text, opened as a long press on the row does, and closed again.
        var first = page.cfgShape.length ? page.cfgShape[0].rows[0] : null;
        var row = first ? StableRows.findRow(page, "key", first.key) : null;
        var btn = row && row.item ? StableRows.findHelp(row.item) : null;
        if (btn && btn.help !== "") {
            btn.holdStarted();
            btn.holdEnded();
            console.log("stoandl-smoke: help " + first.key + " shown=" + btn.toolTipVisible + " · " + btn.toolTipText);
            btn.show();   // already open: stays open
            if (btn.toolTipVisible) btn.released();
        }
        // A locked row (built ones only): its (?) still opens.
        var lockedRow = null;
        off.forEach(function (k) { if (!lockedRow) { var r = StableRows.findRow(page, "key", k); if (r && r.item) lockedRow = r; } });
        var lockedHelp = lockedRow ? StableRows.findHelp(lockedRow.item) : null;
        if (lockedHelp && lockedHelp.help !== "") {
            lockedHelp.show();
            console.log("stoandl-smoke: locked " + lockedRow.key + " help enabled=" + lockedHelp.enabled
                        + " shown=" + lockedHelp.toolTipVisible);
            if (lockedHelp.toolTipVisible) lockedHelp.released();
        }
        // The first combo row: a long press opens its help, not its picker; a click opens the page's one
        // picker on its options with the stored one checked, and picking that one writes it back unchanged.
        var combo = null;
        page.cfgShape.forEach(function (g) {
            if (g.advanced && !page.advancedOpen) return;
            g.rows.forEach(function (r) { if (!combo && r.type === "combo" && page.cfgRows[r.key].enabled) combo = r.key; });
        });
        var comboRow = combo ? StableRows.findRow(page, "key", combo) : null;
        if (comboRow && comboRow.item) {
            comboRow.item.pressAndHold();
            comboRow.item.released();
            var comboHelp = StableRows.findHelp(comboRow.item);
            console.log("stoandl-smoke: long press on " + combo + " help shown=" + (comboHelp ? comboHelp.toolTipVisible : "none")
                        + " picker open=" + (pickerLoader.item ? pickerLoader.item.visible : false));
            if (comboHelp && comboHelp.toolTipVisible) comboHelp.released();
            comboRow.item.clicked();
            var pk = pickerLoader.item;
            console.log("stoandl-smoke: picker '" + pk.title + "' " + pk.options.length + " options, checked "
                        + pk.currentIndex + " '" + pk.options[pk.currentIndex] + "' visible=" + pk.visible);
            pk.pick(pk.currentIndex);
            console.log("stoandl-smoke: picker wrote " + combo + " back: '" + page.cfgValues[combo] + "'");
        }
        if (weatherCard.item) {
            var r = StoandlClient.searchWeatherPlace("Berlin");
            console.log("stoandl-smoke: weather search " + r.kind + ", " + (r.places || []).length + " places"
                        + " searchOn=" + weatherCard.item.searchOn);
        }
        if (ttsCard.item && typeof ttsCard.item.smokeExercise === "function")
            ttsCard.item.smokeExercise();
        // The links open their pages (and run their own hooks once they are loaded).
        anchorKeys.filter(function (k) { return k.indexOf("@link") > 0; }).forEach(function (k) {
            var link = StableRows.findRow(page, "key", k);
            if (!link || !link.item) return;
            link.item.clicked();
            var sub = applicationWindow().pageStack.currentItem;
            console.log("stoandl-smoke: link " + k + " opened '" + sub.title + "'");
            if (typeof sub.smokeExercise === "function")
                applicationWindow().smokeWhenIdle(sub.smokeExercise.bind(sub));
            applicationWindow().smokeWhenIdle(function () { applicationWindow().pageStack.pop(); });
        });
    }

    Connections {
        target: StoandlClient
        function onDaemonUpChanged() { if (StoandlClient.daemonUp) page.reload(); }
        // Any client (or the daemon) wrote a key: re-read once the burst is over (an edit here sends one too).
        function onConfigChanged(key) { configChangedTimer.restart(); }
    }
    Timer {
        id: configChangedTimer
        interval: 200
        onTriggered: page.reload()
    }

    Component.onCompleted: page.reload()

    // Restart stoandl for the keys that need it (any page's).
    RestartMessage {
        Layout.fillWidth: true
        keyInfo: page.keyInfo
    }

    Kirigami.PlaceholderMessage {
        visible: StoandlClient.daemonUp && page.loadedOnce && page.cfgShape.length === 0
        Layout.fillWidth: true
        Layout.topMargin: Kirigami.Units.gridUnit * 4
        icon.name: "settings-configure-symbolic"
        text: "No settings here"
        explanation: "This stoandl has no settings for " + page.pageName + "."
    }

    // One FormHeader + FormCard per section; the Advanced ones after the toggle row (advancedToggle).
    Repeater {
        model: page.cfgShape
        onItemAdded: (index, item) => page.placeCards(item)
        delegate: ColumnLayout {
            id: groupItem
            required property var modelData
            required property int index
            readonly property bool shown: !modelData.advanced || page.advancedOpen
            property alias cardSlot: cardSlot
            Layout.fillWidth: true
            spacing: 0

            // The toggle row sits before the first Advanced section.
            FormCard.FormCard {
                visible: groupItem.modelData.advanced && (groupItem.index === 0 || !page.cfgShape[groupItem.index - 1].advanced)
                Layout.topMargin: page.hasNormal ? Kirigami.Units.largeSpacing : 0
                FormCard.FormButtonDelegate {
                    text: page.advancedOpen ? "Hide advanced settings" : "Advanced settings (" + page.advancedCount + ")"
                    icon.name: "configure-symbolic"
                    trailingLogo.direction: page.advancedOpen ? Qt.UpArrow : Qt.DownArrow
                    onClicked: page.advancedOpen = !page.advancedOpen
                }
            }

            FormCard.FormHeader {
                visible: groupItem.shown
                title: groupItem.modelData.title
            }

            FormCard.FormCard {
                visible: groupItem.shown
                Repeater {
                    model: groupItem.modelData.rows
                    // One Loader per key. modelData is only {key, type}; the row's schema, value and
                    // state are looked up here, on the Loader, where `page` resolves (inside the inline
                    // Components it doesn't — gui/CLAUDE.md, "QML scope gotcha"), so the Components read
                    // only cfgLoader.*. They are defined INLINE so they resolve `cfgLoader` (a Loader
                    // cannot satisfy a required property on a page-scoped Component).
                    //
                    // The first section's rows are built at once, with the page's data, so the screen the
                    // page opens on is complete in its first frame; the rest are built asynchronously below
                    // it and hold a row's height until they are ready, so the page doesn't jump. A search
                    // hit builds them all at once, so its row's position is final. Advanced rows are built
                    // when their sections are opened.
                    delegate: Loader {
                        id: cfgLoader
                        required property var modelData
                        readonly property string key: modelData.anchor || modelData.key
                        readonly property var field: page.cfgFields[key] || ({})
                        readonly property var row: page.cfgRows[key] || ({ description: "", enabled: true })
                        readonly property string value: page.cfgValues[key] || ""
                        Layout.fillWidth: true
                        Layout.preferredHeight: status === Loader.Ready || !active ? -1 : Kirigami.Units.gridUnit * 3
                        active: groupItem.shown
                        asynchronous: groupItem.index > 0 && page.focusKey === ""
                        onLoaded: if (modelData.key === page.focusKey) focusFlash.reveal(cfgLoader)
                        sourceComponent: modelData.type === "toggle" ? cfgToggle
                                       : modelData.type === "combo"  ? cfgCombo
                                       : modelData.type === "int"    ? cfgInt
                                       : modelData.type === "secret" ? cfgSecret
                                       : modelData.type === "list"   ? cfgList
                                       : modelData.type === "@preview" ? anchorPreview
                                       : modelData.type === "@link"  ? anchorLink
                                       : cfgText   // text and any future kind

                        // The rows outlive an edit, so each handler puts its control back on the re-read
                        // value: a value the daemon refused (unchanged, so no binding fires) would
                        // otherwise stay on screen as if it had been stored.
                        Component {
                            id: cfgToggle
                            FormSwitchRow {
                                id: sw
                                text: cfgLoader.field.label || ""
                                description: cfgLoader.row.description
                                help: cfgLoader.field.help || ""
                                locked: !cfgLoader.row.enabled
                                // Only the initial value: FormSwitchDelegate assigns `checked` from its
                                // inner Switch, which drops any binding, so it follows by hand.
                                checked: cfgLoader.value === "true"
                                Connections {
                                    target: cfgLoader
                                    function onValueChanged() { sw.checked = cfgLoader.value === "true"; }
                                }
                                onToggled: {
                                    page.applyConfig(cfgLoader.key, sw.checked ? "true" : "false");
                                    sw.checked = cfgLoader.value === "true";
                                }
                            }
                        }

                        // A combo: the label and the stored value; a click opens the page's one
                        // OptionPicker. The row only shows what the daemon stored, so a refused pick
                        // leaves it as it was.
                        Component {
                            id: cfgCombo
                            FormOptionRow {
                                text: cfgLoader.field.label || ""
                                description: cfgLoader.row.description
                                help: cfgLoader.field.help || ""
                                locked: !cfgLoader.row.enabled
                                value: cfgLoader.value
                                onActivated: {
                                    var key = cfgLoader.key;
                                    var options = cfgLoader.field.options || [];
                                    // The picker checks the stored value; none when it is not an option.
                                    page.pickOption(text, options, options.indexOf(cfgLoader.value),
                                                    function (i, option) { page.applyConfig(key, option); });
                                }
                            }
                        }

                        // Number: the shared FormSpinRow (bounded, unit in the display text, a debounced
                        // commit, and it follows the re-read value between edits).
                        Component {
                            id: cfgInt
                            FormSpinRow {
                                label: cfgLoader.field.label || ""
                                description: cfgLoader.row.description
                                help: cfgLoader.field.help || ""
                                locked: !cfgLoader.row.enabled
                                from: cfgLoader.field.min || 0
                                to: cfgLoader.field.max || 0
                                unit: cfgLoader.field.unit || ""
                                // Clamped into the schema's range so the spin box never starts outside its bounds.
                                value: {
                                    var n = parseInt(cfgLoader.value, 10);
                                    var lo = cfgLoader.field.min || 0, hi = cfgLoader.field.max || 0;
                                    return isNaN(n) ? lo : Math.max(lo, Math.min(hi, n));
                                }
                                onCommit: (newValue) => page.applyConfig(cfgLoader.key, String(newValue))
                            }
                        }

                        // A secret (an API key): the daemon keeps it in the keyring and reports only "set"
                        // or empty, so the field starts blank, shows dots, and an empty commit leaves the
                        // stored value alone ("Remove" clears it).
                        Component {
                            id: cfgSecret
                            ColumnLayout {
                                spacing: 0
                                FormTextRow {
                                    id: sf
                                    locked: !cfgLoader.row.enabled
                                    label: cfgLoader.field.label || ""
                                    description: cfgLoader.row.description +
                                        (cfgLoader.value === "set" ? " (stored)" : " (not set)")
                                    help: cfgLoader.field.help || ""
                                    echoMode: TextInput.Password
                                    placeholderText: cfgLoader.value === "set" ? "••••••••" : ""
                                    onEditingFinished: {
                                        if (sf.value !== "") {
                                            page.applyConfig(cfgLoader.key, sf.value);
                                            sf.value = "";   // never kept on screen, stored or not
                                        }
                                    }
                                }
                                FormCard.FormButtonDelegate {
                                    visible: cfgLoader.value === "set"
                                    enabled: cfgLoader.row.enabled
                                    text: "Remove " + (cfgLoader.field.label || "")
                                    onClicked: page.applyConfig(cfgLoader.key, "")
                                }
                            }
                        }

                        // A list: one row per item (add, remove, reorder); items may contain commas.
                        Component {
                            id: cfgList
                            FormListRow {
                                label: cfgLoader.field.label || ""
                                description: cfgLoader.row.description
                                help: cfgLoader.field.help || ""
                                locked: !cfgLoader.row.enabled
                                value: cfgLoader.value
                                placeholderText: cfgLoader.field.placeholder || ""
                                onCommit: (newValue) => page.applyConfig(cfgLoader.key, newValue)
                            }
                        }

                        // Text, via the shared FormTextRow (which exists because FormTextFieldDelegate has
                        // no `description` and calls i18ndc()). The schema's placeholder documents the
                        // expected shape.
                        Component {
                            id: cfgText
                            FormTextRow {
                                id: tf
                                label: cfgLoader.field.label || ""
                                description: cfgLoader.row.description
                                help: cfgLoader.field.help || ""
                                locked: !cfgLoader.row.enabled
                                value: cfgLoader.value
                                placeholderText: cfgLoader.field.placeholder || ""
                                // Commit on focus-out / Enter only: committing per keystroke would write a
                                // half-typed value on every key.
                                onEditingFinished: {
                                    if (tf.value !== cfgLoader.value) {
                                        page.applyConfig(cfgLoader.key, tf.value);
                                        tf.value = Qt.binding(function () { return cfgLoader.value; });
                                    }
                                }
                            }
                        }

                        // notification.app_name: the watch's notification card with the app name where the
                        // stored value puts it.
                        Component {
                            id: anchorPreview
                            Item {
                                implicitHeight: preview.implicitHeight + Kirigami.Units.largeSpacing * 2
                                WatchCardPreview {
                                    id: preview
                                    anchors.centerIn: parent
                                    appName: "NeoChat"
                                    placement: preview.placementOf(cfgLoader.value) || "small"
                                }
                            }
                        }

                        // A page that belongs here but isn't stoandl.conf (calendar accounts, the health
                        // profile on the watch).
                        Component {
                            id: anchorLink
                            FormCard.FormButtonDelegate {
                                readonly property var anchor: page.rowAnchors[cfgLoader.key] || ({})
                                text: anchor.text || ""
                                description: anchor.description || ""
                                icon.name: anchor.icon || ""
                                onClicked: page.openTarget(anchor.target)
                            }
                        }
                    }
                }
            }

            // The cards anchored to this section's keys move in here (placeCards).
            ColumnLayout {
                id: cardSlot
                Layout.fillWidth: true
                visible: groupItem.shown
                spacing: 0
            }
        }
    }

    // Where the cards wait while their section is absent or being rebuilt (invisible, so the layout skips
    // it). They are built asynchronously: they sit under their section, and their first reads block.
    // Built asynchronously, except for a search hit's page: a card above the hit's row would otherwise
    // arrive after the scroll and push the row down.
    Item {
        id: cardPark
        visible: false

        // Speech-to-text models: download, remove; a finished download or a removal changes the Model
        // dropdown (StoandlClient drops its cached schema when the installed set changes).
        Loader {
            id: sttCard
            Layout.fillWidth: true
            asynchronous: page.focusKey === ""
            active: page.cfgFields["voice.local_model"] !== undefined
            sourceComponent: VoiceModelsCard { kind: "stt"; onChanged: page.reload() }
        }

        // Voices for text to speech, and the Test voice button.
        Loader {
            id: ttsCard
            Layout.fillWidth: true
            asynchronous: page.focusKey === ""
            active: page.cfgFields["tts.local_voice"] !== undefined
            sourceComponent: VoiceModelsCard { kind: "tts"; onChanged: page.reload() }
        }

        // City search: adds a found place to weather.locations, then re-reads the config.
        Loader {
            id: weatherCard
            Layout.fillWidth: true
            asynchronous: page.focusKey === ""
            active: page.cfgFields["weather.place_search"] !== undefined
            sourceComponent: WeatherSearchCard {
                searchOn: page.cfgValues["weather.place_search"] === "true"
                onChanged: page.reloadValues()
            }
        }
    }

    // A search hit's row: scrolled to and flashed once it is built.
    FocusFlash {
        id: focusFlash
        flickable: page.flickable
    }

    // The picker every combo row opens (pickOption), built on first use.
    Loader {
        id: pickerLoader
        active: false
        sourceComponent: OptionPicker {}
    }
}
