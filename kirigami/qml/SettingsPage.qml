import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// Settings landing page. Per KDE HIG, a settings surface this large is a list of categories that push
// focused sub-pages, not one long scroll. The list below holds only each entry's icon and order: a
// schema page's description is its section titles (GetConfigSchema), and a schema page missing from
// the list shows up under "More", so a page the daemon adds is never dropped. The search field at the
// top finds a setting by its name, description, help or key, here and among the watch's own settings.
Kirigami.ScrollablePage {
    id: page
    objectName: "settings"
    title: "Settings"

    // GetConfigSchema rows; ListWatchPrefs rows once the search field had focus (it can block for 5 s
    // daemon-side while the watch's settings load, so it isn't read before someone searches).
    property var schema: []
    property var prefs: []
    property bool prefsAsked: false     // an answer came (maybe empty: no watch yet, its prefs not loaded)
    property bool prefsPending: false
    // The search's hits: [{text, description, kind: "schema"|"watch", pageName, key}].
    property var hits: []
    readonly property bool searching: searchField.text.trim() !== ""

    // The landing list, in order. `pageName` is a schema page; Diagnostics & developer also shows the
    // Developer page's keys at its top.
    readonly property var entries: [
        { kind: "watch",  text: "Watch preferences", icon: "chronometer-symbolic" },
        { kind: "schema", pageName: "Notifications", icon: "notifications-symbolic" },
        { kind: "schema", pageName: "Weather", icon: "weather-clear-symbolic" },
        { kind: "schema", pageName: "Calendar", icon: "view-calendar-symbolic" },
        { kind: "schema", pageName: "Music", icon: "media-playback-start-symbolic" },
        { kind: "schema", pageName: "Voice", icon: "audio-input-microphone-symbolic" },
        { kind: "schema", pageName: "Health & battery", icon: "stoandl-heart-symbolic" },
        { kind: "schema", pageName: "Apps & plugins", icon: "view-list-icons-symbolic" },
        { kind: "schema", pageName: "Connection & power", icon: "network-bluetooth-symbolic" },
        { kind: "schema", pageName: "Firmware & language", icon: "system-software-update-symbolic" },
        { kind: "backup", text: "Backup & restore", icon: "document-save-symbolic",
          description: "Save stoandl's settings and data to a file, or restore them" },
        { kind: "debug",  text: "Diagnostics & developer", pageName: "Developer", icon: "tools-report-bug-symbolic",
          description: "Support bundle, watch logs, recovery and developer tools" },
        { kind: "about",  text: "About", icon: "help-about-symbolic",
          description: "Versions, licence and a line for bug reports" }
    ]

    // page → its section titles in the daemon's order, without the collapsed "Advanced …" ones.
    readonly property var pageSections: {
        var out = {};
        page.schema.forEach(function (f) {
            var l = out[f.page] || (out[f.page] = []);
            if (f.group.indexOf("Advanced") !== 0 && l.indexOf(f.group) < 0)
                l.push(f.group);
        });
        return out;
    }
    // Schema pages no entry names, in the daemon's order.
    readonly property var morePages: Object.keys(page.pageSections).filter(function (p) {
        return !page.entries.some(function (e) { return e.pageName === p; });
    })
    // key → {label}, for the restart message.
    readonly property var keyInfo: {
        var out = {};
        page.schema.forEach(function (f) { out[f.key] = { label: f.label }; });
        return out;
    }
    readonly property var watchSections: page.prefs.reduce(function (l, p) {
        if (l.indexOf(p.section) < 0) l.push(p.section);
        return l;
    }, [])

    Component { id: watchPage;  WatchSettingsPage {} }
    Component { id: schemaPage; SchemaSettingsPage {} }
    Component { id: backupPage; BackupSettingsPage {} }
    Component { id: debugPage;  DebugSettingsPage {} }
    Component { id: aboutPage;  AboutSettingsPage {} }

    function push(component, properties) { return applicationWindow().pushPage(component, properties); }

    function description(e) {
        if (e.kind === "schema") return (page.pageSections[e.pageName] || []).join(" · ");
        if (e.kind === "watch")
            return page.watchSections.length ? page.watchSections.join(" · ") : "The settings stored on the watch itself";
        return e.description;
    }

    function openEntry(e) {
        if (e.kind === "watch") return page.push(watchPage);
        if (e.kind === "schema") return page.push(schemaPage, { pageName: e.pageName });
        if (e.kind === "backup") return page.push(backupPage);
        if (e.kind === "debug") return page.push(debugPage);
        return page.push(aboutPage);
    }

    function openHit(h) {
        if (h.kind === "watch") return page.push(watchPage, { focusId: h.key });
        if (h.pageName === "Developer") return page.push(debugPage);
        return page.push(schemaPage, { pageName: h.pageName, focusKey: h.key });
    }

    function reload() {
        if (!StoandlClient.daemonUp) {
            page.schema = []; page.prefs = []; page.prefsAsked = false; page.prefsPending = false;
            return;
        }
        StoandlClient.fetch(page, ["configSchema"], function (rows) { page.schema = rows || []; });
    }
    function refreshOnShow() { page.reload(); }

    // The watch's settings, for the search: read when the field gets focus (it can block daemon-side, so
    // not before), and kept once there are some. An empty answer (no watch yet, or its prefs not loaded)
    // is asked again on the next focus, or when the watch list changes while the field has it.
    function askPrefs() {
        if (page.prefsPending || page.prefs.length > 0 || !StoandlClient.daemonUp) return;
        page.prefsPending = true;
        StoandlClient.fetch(prefsFetcher, ["listWatchPrefs"], function (rows) {
            page.prefsPending = false;
            page.prefsAsked = true;
            page.prefs = rows || [];
            page.search();
        });
    }
    QtObject { id: prefsFetcher }

    // Case-insensitive, every word somewhere in the label, description, help or key.
    function search() {
        var words = searchField.text.trim().toLowerCase().split(/\s+/).filter(function (w) { return w !== ""; });
        if (words.length === 0) { page.hits = []; return; }
        var matches = function (texts) {
            var hay = texts.join("\n").toLowerCase();
            return words.every(function (w) { return hay.indexOf(w) >= 0; });
        };
        var out = [];
        page.schema.forEach(function (f) {
            if (matches([f.label, f.desc, f.help, f.key]))
                out.push({ kind: "schema", key: f.key, pageName: f.page, text: f.label,
                           description: (f.page === "Developer" ? "Diagnostics & developer" : f.page) + " › " + f.group });
        });
        page.prefs.forEach(function (p) {
            if (matches([p.name, p.description, p.help, p.id]))
                out.push({ kind: "watch", key: p.id, text: p.name, description: "Watch preferences › " + p.section });
        });
        // Hits by name first, then the ones found in a description, help or key.
        var byName = function (h) { return words.every(function (w) { return h.text.toLowerCase().indexOf(w) >= 0; }) ? 0 : 1; };
        page.hits = out.map(function (h, i) { return { h: h, k: byName(h), i: i }; })
                       .sort(function (a, b) { return a.k - b.k || a.i - b.i; })
                       .map(function (x) { return x.h; });
    }

    // Headless smoke (STOANDL_SMOKE_MS): a search (schema and watch hits), opening a hit, then every
    // sub-page and its own smokeExercise() (Main.smokeWhenIdle runs each once its loads are in).
    function smokeExercise() {
        var win = applicationWindow();
        console.log("stoandl-smoke: settings entries " + page.entries.length + ", more " + page.morePages.length
                    + ": " + page.entries.map(function (e) { return (e.text || e.pageName) + " [" + page.description(e) + "]"; }).join(", "));
        searchField.forceActiveFocus();
        searchField.text = "quiet";
        win.smokeWhenIdle(function () {
            page.search();   // the debounce, at once
            console.log("stoandl-smoke: search 'quiet' " + page.hits.length + " hits: "
                        + page.hits.slice(0, 4).map(function (h) { return h.text + " — " + h.description; }).join("; "));
            searchField.text = "location";
            page.search();
            var hit = page.hits.filter(function (h) { return h.kind === "schema"; })[0];
            searchField.text = "";
            if (hit) {
                var sub = page.openHit(hit);
                console.log("stoandl-smoke: opened hit " + hit.key + " on " + sub.pageName);
                win.smokeWhenIdle(function () { win.pageStack.pop(page); });
            }
        });
        // One sub-page at a time, as someone would: open it, run its hook (and whatever that queues), go
        // back. Each step waits until the one before is idle (Main.smokeWhenIdle runs depth first).
        var opens = page.entries.map(function (e) { return function () { return page.openEntry(e); }; })
            .concat(page.morePages.map(function (p) { return function () { return page.push(schemaPage, { pageName: p }); }; }));
        opens.forEach(function (open) {
            win.smokeWhenIdle(function () {
                var sub = open();
                if (sub && typeof sub.smokeExercise === "function")
                    win.smokeWhenIdle(sub.smokeExercise.bind(sub));
                win.smokeWhenIdle(function () { win.pageStack.pop(page); });
            });
        });
        win.smokeWhenIdle(function () {
            console.log("stoandl-smoke: exercised " + opens.length + " settings sub-pages");
        });
        // A key that applies after a restart, written back unchanged: the restart message names it, and its
        // Restart now restarts the daemon. Against the mock only.
        win.smokeWhenIdle(function () {
            if (StoandlClient.daemonVersion.indexOf("mock") !== 0) return;
            var c = StoandlClient.getConfig();
            StoandlClient.setConfig("classic.discover", (c.values || {})["classic.discover"] || "true");
            console.log("stoandl-smoke: restart message visible=" + restartMessage.visible + " '" + restartMessage.text + "'");
            var r = StoandlClient.restartDaemon();
            console.log("stoandl-smoke: restart " + r.kind + " " + r.tail);
            // The mock drops its name and takes it again after ~2 s, as the daemon's restart does.
            var ticks = 0;
            var back = function () {
                if ((StoandlClient.restartPending.length > 0 || !StoandlClient.daemonUp) && ++ticks < 100) {
                    win.smokeWhenIdle(back);
                    return;
                }
                console.log("stoandl-smoke: after restart daemonUp=" + StoandlClient.daemonUp
                            + " pending=" + StoandlClient.restartPending.length + " message visible=" + restartMessage.visible);
            };
            win.smokeWhenIdle(back);
        });
    }

    Connections {
        target: StoandlClient
        function onDaemonUpChanged() { page.reload(); }
        function onWatchesChanged() { if (searchField.activeFocus) page.askPrefs(); }
    }
    Component.onCompleted: page.reload()

    Timer {
        id: searchTimer
        interval: 200
        onTriggered: page.search()
    }

    ColumnLayout {
        spacing: 0

        DaemonPlaceholder {
            visible: !StoandlClient.daemonUp
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
        }

        Kirigami.SearchField {
            id: searchField
            visible: StoandlClient.daemonUp
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.largeSpacing
            Layout.leftMargin: Kirigami.Units.largeSpacing
            Layout.rightMargin: Kirigami.Units.largeSpacing
            placeholderText: "Search settings…"
            onActiveFocusChanged: if (activeFocus) page.askPrefs()
            onTextChanged: searchTimer.restart()
        }

        RestartMessage {
            id: restartMessage
            Layout.fillWidth: true
            keyInfo: page.keyInfo
        }

        // --- search results ------------------------------------------------
        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.searching
            Layout.topMargin: Kirigami.Units.largeSpacing

            FormCard.FormTextDelegate {
                visible: page.hits.length === 0
                text: "No setting matches"
                description: page.prefsAsked && page.prefs.length === 0
                    ? "The watch's own settings are searched once a watch is connected." : ""
            }
            Repeater {
                model: page.searching ? page.hits : []
                delegate: FormCard.FormButtonDelegate {
                    required property var modelData
                    text: modelData.text
                    description: modelData.description
                    onClicked: page.openHit(modelData)
                }
            }
        }

        // --- the categories ------------------------------------------------
        FormCard.FormCard {
            visible: StoandlClient.daemonUp && !page.searching
            Layout.topMargin: Kirigami.Units.largeSpacing

            Repeater {
                model: page.entries
                delegate: ColumnLayout {
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true
                    spacing: 0
                    FormCard.FormDelegateSeparator { visible: index > 0 }
                    FormCard.FormButtonDelegate {
                        text: modelData.text || modelData.pageName
                        description: page.description(modelData)
                        icon.name: modelData.icon
                        onClicked: page.openEntry(modelData)
                    }
                }
            }
        }

        FormCard.FormHeader {
            visible: StoandlClient.daemonUp && !page.searching && page.morePages.length > 0
            title: "More"
        }
        FormCard.FormCard {
            visible: StoandlClient.daemonUp && !page.searching && page.morePages.length > 0
            Repeater {
                model: page.morePages
                delegate: FormCard.FormButtonDelegate {
                    required property string modelData
                    text: modelData
                    description: (page.pageSections[modelData] || []).join(" · ")
                    icon.name: "settings-configure-symbolic"
                    onClicked: page.push(schemaPage, { pageName: modelData })
                }
            }
        }
    }
}
