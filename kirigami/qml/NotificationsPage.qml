import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// Notifications screen. Temp-mute, the per-app list (each row opens a deeper Kirigami.Dialog) and regex
// filters; the stoandl.conf side (forwarding, the app name on the watch, …) is Settings → Notifications,
// one toolbar action away. While notification.forward is off, a banner says so with a Turn on button (the
// key's one control is in Settings; StoandlClient.forwarding follows it). Everything is re-fetched in
// reload(): every mutation re-fetches its slice (handoff hard rules).
Kirigami.ScrollablePage {
    id: page
    objectName: "notifications"
    title: "Alerts"   // matches the (shortened) nav tab label

    // --- live snapshots (all re-fetched in reload()) -----------------------
    property var apps: []                   // notifList() rows
    property var filters: []                // notifListFilters() rows

    // The temporary mute of every app (NotifSetMuteAll), separate from the per-app mutes: StoandlClient
    // holds when it ends (the Watch tab's chip shows the same).
    readonly property bool allMuted: StoandlClient.mutedUntil > 0

    // The per-app list's search and order ("recent": most recently notified first, or "name").
    property string query: ""
    property string sortBy: "recent"
    readonly property var shownApps: {
        var q = page.query.trim().toLowerCase();
        var rows = page.apps.filter(function (a) { return q === "" || a.name.toLowerCase().indexOf(q) >= 0; });
        return rows.sort(page.sortBy === "name"
            ? function (a, b) { return a.name.localeCompare(b.name); }
            : function (a, b) { return Number(b.lastNotified || 0) - Number(a.lastNotified || 0); });
    }

    // notification.app_name's options (WatchCardPreview's table: label and placement token).
    readonly property var appNamePlacements: dialogPreview.placements
    // notification.app_name as a token: what an app on "Default" follows. reload() reads it with
    // GetConfig; "" until then (or from a daemon without the key).
    property string appNameGlobal: ""
    // notification.images, for the per-app images switch's hint; reload() reads it.
    property bool imagesGlobal: true

    // An app's standing mute (NotifSetMute takes the token), in notification.default_mute's words.
    readonly property var muteStates: [
        { text: "Unmuted", value: "never" }, { text: "Muted", value: "always" },
        { text: "Muted on weekdays", value: "weekdays" }, { text: "Muted at weekends", value: "weekends" }
    ]

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    // The label of a placement token ("Small line" for small); "" for one that isn't offered.
    function appNameLabel(token) {
        var i = page.optionIndex(page.appNamePlacements, token);
        return i >= 0 ? page.appNamePlacements[i].text : "";
    }

    // Index of the option whose value is `v` (case-insensitive, like the daemon's TimelineColor.findByName);
    // -1 when none is. Values only: NotifList reports colours and placements by value, and matching labels
    // too would pick the wrong colour ("Yellow" is ChromeYellow's label but its own TimelineColor).
    function optionIndex(options, v) {
        var s = String(v || "").toLowerCase();
        for (var i = 0; i < options.length; ++i) {
            if (options[i].value.toLowerCase() === s)
                return i;
        }
        return -1;
    }
    // The label of the option whose value is `v`, else the first option's ("Default").
    function optionText(options, v) {
        return options.length ? options[Math.max(0, page.optionIndex(options, v))].text : "";
    }

    function fmtUntil(epoch) { return applicationWindow().formatUntil(epoch); }
    // An app's mute as one line: "Muted until 14:30", "Muted on weekdays", … ("" while unmuted).
    function muteText(app) {
        if (!app || !app.muteKind || app.muteKind === "never") return "";
        if (app.muteKind === "until") return "Muted until " + page.fmtUntil(app.mutedUntil);
        return page.optionText(page.muteStates, app.muteKind);
    }
    // A mute the app's switch can't show (a schedule, or one that ends): the switch opens the dialog instead.
    function scheduled(app) { return app.muteKind === "weekdays" || app.muteKind === "weekends" || app.muteKind === "until"; }

    // Per-app temporary mutes are durations to the daemon: "today" is the minutes left until midnight.
    function untilMidnight() {
        var now = new Date();
        var midnight = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1);
        return Math.ceil((midnight - now) / 60000) + "m";
    }

    // Asynchronous (one round of parallel reads); the latest call wins. An unchanged list keeps its rows.
    function reload() {
        if (!StoandlClient.daemonUp)
            return;
        StoandlClient.refreshMuteAll();
        StoandlClient.fetch(page, [["notifList"], ["notifListFilters"], ["getConfig"]], function (r) {
            if (JSON.stringify(r[0]) !== JSON.stringify(page.apps)) page.apps = r[0];
            if (JSON.stringify(r[1]) !== JSON.stringify(page.filters)) page.filters = r[1];
            var values = (r[2] && r[2].values) ? r[2].values : {};
            page.appNameGlobal = dialogPreview.placementOf(values["notification.app_name"]);
            var img = values["notification.images"];
            page.imagesGlobal = img === undefined || String(img).toLowerCase() !== "false";
            page.refreshing = false;
        });
    }

    // Kept while another tab shows (Main.qml): re-read when it comes back.
    function refreshOnShow() { page.reload(); }

    supportsRefreshing: true
    onRefreshingChanged: if (refreshing) page.reload()

    Component { id: notificationSettingsPage; SchemaSettingsPage { pageName: "Notifications" } }

    // Mute every app for a while (30m / 1h / today); per-app mutes stay as they are. "never" resumes.
    function muteAll(spec) {
        if (spec === "never")
            return applicationWindow().resumeNotifications();
        var r = StoandlClient.notifSetMuteAll(spec);
        page.toast(r.ok ? r.tail : "Mute failed: " + (r.tail || r.kind));
    }

    // One app's mute: a standing state, a duration, or "never" to resume. The toast says what now holds.
    function setMute(name, spec, what) {
        var r = StoandlClient.notifSetMute(name, spec);
        page.toast(r.ok ? what : "Mute failed: " + (r.tail || r.kind));
        page.reload();
    }

    // A filter goes at once; Undo on the toast adds it back (its pattern and action are all it is).
    function removeFilter(f) {
        var r = StoandlClient.notifRemoveFilter(f.pattern);
        if (r.ok) {
            applicationWindow().showPassiveNotification("Removed filter " + f.pattern, "long", "Undo", function () {
                var back = StoandlClient.notifAddFilter(f.pattern, f.action);
                if (!back.ok)
                    page.toast("Could not add it back: " + (back.tail || back.kind));
                page.reload();
            });
        } else {
            page.toast("Remove failed: " + (r.tail || r.kind));
        }
        page.reload();
    }

    // The page's one option picker (the dialog's rows), built on first use.
    function pick(title, options, index, onPicked) {
        pickerLoader.active = true;
        pickerLoader.item.choose(title, options.map(function (o) { return o.text; }), index, onPicked);
    }

    Connections {
        target: StoandlClient
        enabled: page.visible
        function onDaemonUpChanged() { if (StoandlClient.daemonUp) page.reload(); }
        // notification.app_name or .images changed (Settings, the CLI): the per-app dialog follows them.
        function onConfigChanged(key) { if (key.indexOf("notification.") === 0) page.reload(); }
    }

    Component.onCompleted: page.reload()

    // Push one through the real send path — the same choke point desktop and extension notifications
    // use, so per-app mute, the filters and the master switch all apply. That is the point: it answers
    // "is anything on this screen stopping my notifications?" rather than bypassing them to look good.
    function sendTest() {
        var r = StoandlClient.call("SendTestNotification",
                                   ["Test notification", "Sent from stoandl at " + Qt.formatTime(new Date(), "HH:mm")]);
        if (r.ok) {
            page.toast("Test notification sent to the watch");
        } else {
            page.toast(r.kind === "notready" ? "No watch connected"
                                             : "Not sent: " + (r.tail || r.kind));
        }
        page.reload();
    }

    // What a WatchCardPreview shows, for the smoke log.
    function smokePreview(preview) {
        console.log("stoandl-smoke: preview " + preview.placement + ": " + preview.summary);
    }

    // Headless smoke harness (STOANDL_SMOKE_MS) — see Main.qml. Covers the send-test path, the only
    // control on this page that goes through SendTestNotification, the forwarding-off banner, the
    // temporary mute of all apps, the list's search and order and the per-app dialog, which only a click
    // reaches. The writes run against the mock only (a real daemon would drop notifications meanwhile),
    // except the app-name placement, which is written back unchanged.
    function smokeExercise() {
        var win = applicationWindow();
        // Guarded like the action itself: with the daemon down the button is disabled, so firing it
        // here would exercise a path a user cannot reach and log a misleading D-Bus error.
        if (StoandlClient.daemonUp)
            page.sendTest();
        console.log("stoandl-smoke: alerts rows " + page.shownApps.map(function (a) {
            return a.name + (page.muteText(a) !== "" ? "(" + page.muteText(a) + ")" : ""); }).join(", "));
        page.sortBy = "name";
        page.query = "a";
        console.log("stoandl-smoke: alerts by name, 'a': " + page.shownApps.map(function (a) { return a.name; }).join(", "));
        page.sortBy = "recent";
        page.query = "";
        var mock = StoandlClient.daemonUp && StoandlClient.daemonVersion.indexOf("mock") === 0;
        if (mock && StoandlClient.forwarding) {
            StoandlClient.setConfig("notification.forward", "false");
            win.smokeWhenIdle(function () {
                console.log("stoandl-smoke: forwarding off banner=" + forwardBanner.visible);
                forwardBanner.turnOn();
                win.smokeWhenIdle(function () {
                    console.log("stoandl-smoke: forwarding on again banner=" + forwardBanner.visible);
                });
            });
        }
        if (mock) {
            page.muteAll("30m");
            win.smokeWhenIdle(function () {
                console.log("stoandl-smoke: mute all -> allMuted=" + page.allMuted + " '" + muteAllLabel.text + "'");
                page.muteAll("never");
                win.smokeWhenIdle(function () { console.log("stoandl-smoke: resumed allMuted=" + page.allMuted); });
            });
        }
        // The per-app dialog, for an app with an app-name override if there is one: its preselection
        // comes from NotifList's 7th column, and the same value goes back through NotifSetAppName
        // (a no-op change, also against a real daemon). Its preview shows that override, then Default
        // (which follows the global placement), then the override again.
        var a = page.apps.find(function (x) { return x.appNamePlacement !== ""; }) || page.apps[0];
        if (!StoandlClient.daemonUp || !a) {
            console.log("stoandl-smoke: exercised notifications page");
            return;
        }
        win.smokeWhenIdle(function () {
            appDialog.openFor(a);
            win.smokeWhenIdle(function () {
                page.smokePreview(dialogPreview);
                console.log("stoandl-smoke: notif dialog " + a.name + " mute='" + muteRow.value + "' icon='" + iconRow.value
                            + "' colour='" + colorRow.value + "' app name='" + appNameRow.value + "' vibes=" + appDialog.vibes.length);
                var placement = a.appNamePlacement || "default";
                StoandlClient.notifSetAppName(a.name, "default");
                page.reload();
                win.smokeWhenIdle(function () {
                    page.smokePreview(dialogPreview);
                    var r = StoandlClient.notifSetAppName(a.name, placement);
                    page.reload();
                    win.smokeWhenIdle(function () {
                        console.log("stoandl-smoke: notif app name: " + a.name + " = " + appNameRow.value + " (" + r.kind + ")");
                        if (mock)
                            page.smokeVibration();
                        else
                            appDialog.close();
                        console.log("stoandl-smoke: exercised notifications page");
                    });
                });
            });
        });
    }

    // A custom vibration (mock only): saved through the editor, listed in the dialog, removed again.
    function smokeVibration() {
        var win = applicationWindow();
        vibeEditor.openFor(null);
        vibeName.text = "Smoke";
        vibePattern.text = "200, 100, 200";
        vibeEditor.save(vibeEditor.pattern, "saved");
        win.smokeWhenIdle(function () {
            var v = appDialog.vibes.find(function (x) { return x.value === "Smoke"; });
            console.log("stoandl-smoke: custom vibration listed=" + (v !== undefined) + " pattern=" + (v ? v.pattern : "")
                        + " custom=" + (v ? v.custom : ""));
            vibeEditor.openFor(v);
            vibeEditor.save("", "removed");
            win.smokeWhenIdle(function () {
                console.log("stoandl-smoke: custom vibration removed=" + !appDialog.vibes.some(function (x) { return x.value === "Smoke"; }));
                appDialog.close();
            });
        });
    }

    actions: [
        Kirigami.Action {
            icon.name: "mail-send-symbolic"
            text: "Send test"
            enabled: StoandlClient.daemonUp
            onTriggered: page.sendTest()
        },
        Kirigami.Action {
            icon.name: "settings-configure-symbolic"
            text: "Notification settings"
            enabled: StoandlClient.daemonUp
            onTriggered: applicationWindow().pushPage(notificationSettingsPage)
        },
        Kirigami.Action {
            icon.name: "list-add"
            text: "Add filter"
            enabled: StoandlClient.daemonUp
            onTriggered: filterDialog.openForNew()
        }
    ]

    ColumnLayout {
        spacing: 0

        // --- daemon-not-running state --------------------------------------
        DaemonPlaceholder {
            visible: !StoandlClient.daemonUp
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
        }

        ReadErrorMessage {
            id: readError
            Layout.fillWidth: true
            reads: ["notifList", "notifListFilters"]
            what: "notification settings"
        }

        // ============ FORWARDING OFF + TEMP MUTE ============
        ForwardingBanner {
            id: forwardBanner
            Layout.fillWidth: true
        }

        FormCard.FormHeader {
            visible: StoandlClient.daemonUp
            title: "All apps"
        }

        FormCard.FormCard {
            visible: StoandlClient.daemonUp

            // Temporary mute of every app (30m / 1h / today), or Resume while one runs.
            FormCard.AbstractFormDelegate {
                Layout.fillWidth: true
                background: null
                contentItem: ColumnLayout {
                    spacing: Kirigami.Units.smallSpacing
                    QQC2.Label {
                        id: muteAllLabel
                        Layout.fillWidth: true
                        text: page.allMuted ? "Muted until " + page.fmtUntil(StoandlClient.mutedUntil)
                                            : "Mute temporarily"
                        font: Kirigami.Theme.smallFont
                        opacity: 0.7
                    }
                    RowLayout {
                        spacing: Kirigami.Units.smallSpacing
                        QQC2.Button {
                            visible: page.allMuted
                            text: "Resume now"
                            icon.name: "media-playback-start-symbolic"
                            onClicked: page.muteAll("never")
                        }
                        QQC2.Button {
                            visible: !page.allMuted
                            text: "30 min"
                            onClicked: page.muteAll("30m")
                        }
                        QQC2.Button {
                            visible: !page.allMuted
                            text: "1 hr"
                            onClicked: page.muteAll("1h")
                        }
                        QQC2.Button {
                            visible: !page.allMuted
                            text: "Today"
                            onClicked: page.muteAll("today")
                        }
                    }
                }
            }
        }

        // ============ PER-APP ============
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp && page.apps.length > 0
            title: "Per-app"
        }

        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.apps.length > 0

            // Search and order (most recent first, or by name).
            FormCard.AbstractFormDelegate {
                Layout.fillWidth: true
                background: null
                hoverEnabled: false
                contentItem: RowLayout {
                    spacing: Kirigami.Units.smallSpacing
                    Kirigami.SearchField {
                        Layout.fillWidth: true
                        placeholderText: "Find an app"
                        text: page.query
                        onTextChanged: page.query = text
                    }
                    QQC2.ToolButton {
                        icon.name: page.sortBy === "name" ? "view-sort-ascending-name" : "view-sort-descending"
                        text: page.sortBy === "name" ? "By name" : "Recent"
                        display: QQC2.AbstractButton.TextBesideIcon
                        QQC2.ToolTip.text: page.sortBy === "name" ? "Sorted by name; sort by most recent instead"
                                                                  : "Most recent first; sort by name instead"
                        QQC2.ToolTip.visible: hovered
                        onClicked: page.sortBy = page.sortBy === "name" ? "recent" : "name"
                    }
                }
            }

            FormCard.FormTextDelegate {
                visible: page.shownApps.length === 0
                text: "No app matches “" + page.query + "”"
            }

            Repeater {
                model: page.shownApps

                delegate: FormCard.AbstractFormDelegate {
                    id: appRow
                    required property var modelData

                    onClicked: appDialog.openFor(appRow.modelData)

                    contentItem: RowLayout {
                        spacing: Kirigami.Units.largeSpacing

                        Kirigami.Icon {
                            source: "notifications-symbolic"
                            color: appRow.modelData.muted ? Kirigami.Theme.disabledTextColor
                                                          : Kirigami.Theme.highlightColor
                            implicitWidth: Kirigami.Units.iconSizes.medium
                            implicitHeight: Kirigami.Units.iconSizes.medium
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: appRow.modelData.name
                                elide: Text.ElideRight
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: appRow.modelData.muteKind !== "never" ? page.muteText(appRow.modelData)
                                    : "Vibration · " + (appRow.modelData.vibe || "Default")
                                elide: Text.ElideRight
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                            }
                        }

                        // On = NOT muted. A schedule or a mute that ends isn't on or off: the switch opens the
                        // dialog for it rather than overwriting it. Toggling consumes the click, so the row's
                        // onClicked doesn't fire too.
                        QQC2.Switch {
                            id: muteSwitch
                            checked: !appRow.modelData.muted
                            Accessible.name: "Forward " + appRow.modelData.name
                            onToggled: {
                                var app = appRow.modelData;
                                muteSwitch.checked = Qt.binding(function () { return !appRow.modelData.muted; });
                                if (page.scheduled(app))
                                    appDialog.openFor(app);
                                else
                                    page.setMute(app.name, app.muted ? "never" : "always",
                                                 (app.muted ? "Unmuted " : "Muted ") + app.name);
                            }
                        }

                        Kirigami.Icon {
                            source: "go-next-symbolic"
                            implicitWidth: Kirigami.Units.iconSizes.small
                            implicitHeight: Kirigami.Units.iconSizes.small
                            opacity: 0.6
                        }
                    }
                }
            }
        }

        // ============ FILTERS ============
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp
            title: "Filters"
        }

        FormCard.FormCard {
            visible: StoandlClient.daemonUp

            Kirigami.PlaceholderMessage {
                visible: page.filters.length === 0 && !readError.failed
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.largeSpacing
                Layout.bottomMargin: Kirigami.Units.largeSpacing
                icon.name: "search-symbolic"
                text: "No filters"
                explanation: "Add a regex filter to allow or block matching notifications."
            }

            Repeater {
                model: page.filters

                delegate: FormCard.AbstractFormDelegate {
                    id: filterRow
                    required property var modelData
                    // Non-interactive row (the trailing bin is the only action).
                    hoverEnabled: false

                    contentItem: RowLayout {
                        spacing: Kirigami.Units.largeSpacing

                        Kirigami.Icon {
                            source: "search-symbolic"
                            color: filterRow.modelData.action === "block"
                                   ? Kirigami.Theme.negativeTextColor
                                   : Kirigami.Theme.positiveTextColor
                            implicitWidth: Kirigami.Units.iconSizes.medium
                            implicitHeight: Kirigami.Units.iconSizes.medium
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: filterRow.modelData.pattern
                                elide: Text.ElideRight
                                font.family: "monospace"
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: filterRow.modelData.action === "block"
                                      ? "Block matching" : "Always allow"
                                elide: Text.ElideRight
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                            }
                        }

                        QQC2.ToolButton {
                            icon.name: "edit-delete-remove-symbolic"
                            display: QQC2.AbstractButton.IconOnly
                            QQC2.ToolTip.text: "Remove filter"
                            QQC2.ToolTip.visible: hovered
                            onClicked: page.removeFilter(filterRow.modelData)
                        }
                    }
                }
            }
        }

        QQC2.Label {
            visible: StoandlClient.daemonUp
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.largeSpacing
            text: "Filters use regex on the notification title and body. Block hides matching notifications; allow always forwards them."
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            wrapMode: Text.WordWrap
        }
    }

    // The dialog's one-of-several rows open this picker, built on first use.
    Loader {
        id: pickerLoader
        active: false
        sourceComponent: OptionPicker {}
    }

    // ============ PER-APP DEEPER VIEW (dialog) ============
    Kirigami.Dialog {
        id: appDialog

        property string appName: ""
        // The app's row as the page last read it, so every write shows once page.reload() is in.
        readonly property var app: page.apps.find(function (a) { return a.name === appDialog.appName; }) || ({})

        // Vibrations and icons as the daemon advertises them (NotifStyleChoices, cached by StoandlClient), so
        // a pick is always something NotifSetStyle accepts; "default" drops the override. Read on open.
        property var vibes: []
        property var iconOptions: []
        // A curated subset of the watch's TimelineColor palette; `value` is the enum name the daemon
        // stores (NotifSetStyle takes a name, not a hex — NotifList ships no allowed set, so hardcode).
        // `swatch` is the colour's hex ("" = no override: the watch's default, which WatchCardPreview draws).
        readonly property var colorOptions: [
            { text: "Default", value: "default", swatch: "" },
            { text: "Red",     value: "Red",          swatch: "#FF0000" },
            { text: "Orange",  value: "Orange",       swatch: "#FF5500" },
            { text: "Yellow",  value: "ChromeYellow", swatch: "#FFAA00" },
            { text: "Green",   value: "Green",        swatch: "#00FF00" },
            { text: "Cyan",    value: "Cyan",         swatch: "#00FFFF" },
            { text: "Blue",    value: "BlueMoon",     swatch: "#0055FF" },
            { text: "Violet",  value: "VividViolet",  swatch: "#AA00FF" }
        ]
        // The app's override of notification.app_name; `value` is what NotifSetAppName takes ("default"
        // drops the override, so the app follows the global key and its appNamePlacement is empty).
        readonly property var appNameOptions: [{ text: "Default", value: "default" }].concat(page.appNamePlacements)
        readonly property int colorIndex: Math.max(0, page.optionIndex(appDialog.colorOptions, appDialog.app.color))

        title: appName
        preferredWidth: Math.min(Kirigami.Units.gridUnit * 24, applicationWindow().width - Kirigami.Units.gridUnit * 2)
        // Taller than most windows with the preview, so it scrolls. Kirigami.Dialog slides in from 2 gridUnits
        // lower; at the default maximum that runs past the window's bottom, the popup is squeezed to fit, which
        // moves it again (a binding loop on y and a jumpy open). Leave room for the slide.
        maximumHeight: absoluteMaximumHeight - Kirigami.Units.gridUnit * 4
        standardButtons: QQC2.Dialog.Close
        showCloseButton: true

        readonly property bool temporary: appDialog.app.muteKind === "until"

        function openFor(row) {
            appDialog.appName = row.name;
            appDialog.open();
            appDialog.loadChoices();
        }

        // StoandlClient caches them; a custom vibration saved or removed drops that cache.
        function loadChoices() {
            StoandlClient.fetch(appDialog, ["notifStyleChoices"], function (choices) {
                appDialog.vibes = [{ text: "Default", value: "default" }].concat(choices.vibes || []);
                appDialog.iconOptions = [{ text: "Default", value: "default" }].concat(choices.icons || []);
            });
        }

        // A style write (colour, icon, vibration), toasted, then the page re-reads (the dialog follows it).
        function setStyle(color, icon, vibe, what) {
            var r = StoandlClient.notifSetStyle(appDialog.appName, color, icon, vibe);
            page.toast(r.ok ? what : what.split(" · ")[0] + ": " + (r.tail || r.kind));
            page.reload();
        }

        // The images switch follows the app's row (a toggle assigns `checked`, so it can't stay bound).
        onAppChanged: imagesSwitch.checked = appDialog.app.imagesOff !== true

        ColumnLayout {
            spacing: 0
            Layout.preferredWidth: Kirigami.Units.gridUnit * 24

            // --- the standing mute, then a temporary one ---
            FormOptionRow {
                id: muteRow
                Layout.fillWidth: true
                text: "Mute"
                description: appDialog.temporary ? "A temporary mute; Resume ends it now" : "Whether this app reaches the watch"
                value: appDialog.temporary ? page.muteText(appDialog.app)
                                           : page.optionText(page.muteStates, appDialog.app.muteKind)
                onActivated: page.pick(text, page.muteStates,
                                       appDialog.temporary ? 1 : Math.max(0, page.optionIndex(page.muteStates, appDialog.app.muteKind)),
                                       function (i) {
                                           page.setMute(appDialog.appName, page.muteStates[i].value,
                                                        appDialog.appName + ": " + page.muteStates[i].text);
                                       })
            }

            FormCard.AbstractFormDelegate {
                Layout.fillWidth: true
                background: null
                hoverEnabled: false
                contentItem: ColumnLayout {
                    spacing: Kirigami.Units.smallSpacing
                    QQC2.Label {
                        Layout.fillWidth: true
                        text: appDialog.temporary ? "Muted until " + page.fmtUntil(appDialog.app.mutedUntil) : "Mute temporarily"
                        font: Kirigami.Theme.smallFont
                        opacity: 0.7
                    }
                    RowLayout {
                        spacing: Kirigami.Units.smallSpacing
                        QQC2.Button {
                            visible: appDialog.temporary
                            text: "Resume"
                            icon.name: "media-playback-start-symbolic"
                            onClicked: page.setMute(appDialog.appName, "never", "Unmuted " + appDialog.appName)
                        }
                        QQC2.Button {
                            visible: !appDialog.temporary
                            text: "30 min"
                            onClicked: page.setMute(appDialog.appName, "30m", "Muted " + appDialog.appName + " for 30 minutes")
                        }
                        QQC2.Button {
                            visible: !appDialog.temporary
                            text: "1 hr"
                            onClicked: page.setMute(appDialog.appName, "1h", "Muted " + appDialog.appName + " for an hour")
                        }
                        QQC2.Button {
                            visible: !appDialog.temporary
                            text: "Today"
                            onClicked: page.setMute(appDialog.appName, page.untilMidnight(), "Muted " + appDialog.appName + " until midnight")
                        }
                    }
                }
            }

            Kirigami.Separator { Layout.fillWidth: true }

            // --- vibration radio list ---
            Kirigami.Heading {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.largeSpacing
                Layout.bottomMargin: Kirigami.Units.smallSpacing
                level: 5
                text: "Vibration"
                opacity: 0.7
            }

            Repeater {
                model: appDialog.vibes
                delegate: QQC2.ItemDelegate {
                    id: vibeRow
                    required property var modelData
                    // NotifList reports "" for no override, which is the "default" row.
                    readonly property bool chosen: (appDialog.app.vibe || "default").toLowerCase() === modelData.value.toLowerCase()
                    Layout.fillWidth: true
                    onClicked: appDialog.setStyle("", "", vibeRow.modelData.value, "Vibration · " + vibeRow.modelData.text)
                    contentItem: RowLayout {
                        spacing: Kirigami.Units.largeSpacing
                        Kirigami.Icon {
                            source: "audio-volume-high-symbolic"
                            color: vibeRow.chosen ? Kirigami.Theme.highlightColor : Kirigami.Theme.textColor
                            implicitWidth: Kirigami.Units.iconSizes.smallMedium
                            implicitHeight: Kirigami.Units.iconSizes.smallMedium
                        }
                        QQC2.Label { text: vibeRow.modelData.text; Layout.fillWidth: true; elide: Text.ElideRight }
                        // A custom vibration can be changed or removed (built-ins can't).
                        QQC2.ToolButton {
                            visible: vibeRow.modelData.custom === true
                            icon.name: "document-edit-symbolic"
                            display: QQC2.AbstractButton.IconOnly
                            text: "Edit " + vibeRow.modelData.text
                            QQC2.ToolTip.text: "Edit vibration"
                            QQC2.ToolTip.visible: hovered
                            onClicked: vibeEditor.openFor(vibeRow.modelData)
                        }
                        // Buzzes the connected watch without picking the row.
                        QQC2.ToolButton {
                            text: "Test"
                            flat: true
                            onClicked: {
                                var r = StoandlClient.notifVibeTest(vibeRow.modelData.value);
                                page.toast(r.ok ? r.tail : "Test: " + (r.tail || r.kind));
                            }
                        }
                        Kirigami.Icon {
                            visible: vibeRow.chosen
                            source: "checkmark-symbolic"
                            color: Kirigami.Theme.highlightColor
                            implicitWidth: Kirigami.Units.iconSizes.small
                            implicitHeight: Kirigami.Units.iconSizes.small
                        }
                    }
                }
            }

            FormCard.FormButtonDelegate {
                Layout.fillWidth: true
                text: "New vibration…"
                description: "Your own pattern, for any app and for calendar reminders"
                icon.name: "list-add-symbolic"
                onClicked: vibeEditor.openFor(null)
            }

            Kirigami.Separator { Layout.fillWidth: true }

            // --- options: each row shows what is stored and opens the page's picker ---
            FormOptionRow {
                id: iconRow
                Layout.fillWidth: true
                text: "Custom icon"
                description: "Glyph shown on the watch"
                value: page.optionText(appDialog.iconOptions, appDialog.app.icon)
                onActivated: page.pick(text, appDialog.iconOptions,
                                       Math.max(0, page.optionIndex(appDialog.iconOptions, appDialog.app.icon)),
                                       function (i) {
                                           var o = appDialog.iconOptions[i];
                                           appDialog.setStyle("", o.value, "", "Icon · " + o.text);
                                       })
            }

            FormOptionRow {
                id: colorRow
                Layout.fillWidth: true
                text: "Notification color"
                description: "Accent colour on the watch"
                value: appDialog.colorOptions[appDialog.colorIndex].text
                onActivated: page.pick(text, appDialog.colorOptions, appDialog.colorIndex, function (i) {
                    var o = appDialog.colorOptions[i];
                    appDialog.setStyle(o.value, "", "", "Color · " + o.text);
                })
                Rectangle {
                    visible: appDialog.colorOptions[appDialog.colorIndex].swatch !== ""
                    implicitWidth: Kirigami.Units.iconSizes.small
                    implicitHeight: Kirigami.Units.iconSizes.small
                    radius: width / 2
                    color: appDialog.colorOptions[appDialog.colorIndex].swatch || "transparent"
                    border.color: Kirigami.Theme.disabledTextColor
                }
            }

            FormOptionRow {
                id: appNameRow
                Layout.fillWidth: true
                text: "App name"
                description: "Default follows Settings → Notifications"
                             + (page.appNameGlobal !== "" ? ", now " + page.appNameLabel(page.appNameGlobal) : "") + "."
                value: page.optionText(appDialog.appNameOptions, appDialog.app.appNamePlacement || "default")
                onActivated: page.pick(text, appDialog.appNameOptions,
                                       Math.max(0, page.optionIndex(appDialog.appNameOptions, appDialog.app.appNamePlacement || "default")),
                                       function (i) {
                                           var o = appDialog.appNameOptions[i];
                                           var r = StoandlClient.notifSetAppName(appDialog.appName, o.value);
                                           page.toast(r.ok ? "App name · " + o.text : "App name: " + (r.tail || r.kind));
                                           page.reload();
                                       })
            }

            // The official app's per-app images switch; on follows notification.images.
            FormSwitchRow {
                id: imagesSwitch
                Layout.fillWidth: true
                text: "Send images"
                description: page.imagesGlobal ? "Pictures this app attaches, on watches that show them."
                                               : "Pictures are off for every app (Settings → Notifications → Pictures)."
                onToggled: {
                    var r = StoandlClient.notifSetImages(appDialog.appName, checked ? "on" : "off");
                    page.toast(r.ok ? (checked ? "Images on" : "Images off") : "Images: " + (r.tail || r.kind));
                    page.reload();
                }
            }

            // This app's card as its stored colour and app-name placement put it on the watch.
            WatchCardPreview {
                id: dialogPreview
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: Kirigami.Units.smallSpacing
                Layout.bottomMargin: Kirigami.Units.largeSpacing
                appName: appDialog.appName
                // "Default" follows the global placement; the daemon's default before that is read.
                placement: appDialog.app.appNamePlacement || page.appNameGlobal || "small"
                accent: appDialog.colorOptions[appDialog.colorIndex].swatch
            }
        }
    }

    // ============ CUSTOM VIBRATION (NotifSetVibePattern) ============
    // A name and on/off milliseconds; Test buzzes the watch with the pattern as typed. Saving adds (or, for an
    // existing one, replaces) it; Remove clears it (an empty pattern).
    Kirigami.PromptDialog {
        id: vibeEditor
        title: editing ? "Edit vibration" : "New vibration"
        standardButtons: QQC2.Dialog.NoButton
        preferredWidth: Math.min(Kirigami.Units.gridUnit * 22, applicationWindow().width - Kirigami.Units.gridUnit * 2)

        property bool editing: false
        readonly property string pattern: vibePattern.text.replace(/\s/g, "")

        function openFor(vibe) {
            vibeEditor.editing = vibe !== null;
            vibeName.text = vibe ? vibe.value : "";
            vibePattern.text = vibe ? (vibe.pattern || "") : "";
            vibeEditor.open();
        }

        function save(pattern, what) {
            var r = StoandlClient.notifSetVibePattern(vibeName.text.trim(), pattern);
            page.toast(r.ok ? what : "Vibration: " + (r.tail || r.kind));
            if (r.ok) {
                vibeEditor.close();
                appDialog.loadChoices();
            }
        }

        ColumnLayout {
            spacing: Kirigami.Units.largeSpacing
            QQC2.Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: "Milliseconds on, off, on, … separated by commas (at most 64 parts and 10 seconds), e.g. 200,100,200."
            }
            QQC2.TextField {
                id: vibeName
                Layout.fillWidth: true
                enabled: !vibeEditor.editing
                placeholderText: "Name"
            }
            RowLayout {
                Layout.fillWidth: true
                QQC2.TextField {
                    id: vibePattern
                    Layout.fillWidth: true
                    placeholderText: "200,100,200"
                    inputMethodHints: Qt.ImhPreferNumbers
                    font.family: "monospace"
                }
                QQC2.Button {
                    text: "Test"
                    enabled: vibeEditor.pattern !== ""
                    onClicked: {
                        var r = StoandlClient.notifVibeTest(vibeEditor.pattern);
                        page.toast(r.ok ? r.tail : "Test: " + (r.tail || r.kind));
                    }
                }
            }
        }

        customFooterActions: [
            Kirigami.Action {
                text: "Save"
                icon.name: "document-save-symbolic"
                enabled: vibeName.text.trim() !== "" && vibeEditor.pattern !== ""
                onTriggered: vibeEditor.save(vibeEditor.pattern, "Saved vibration " + vibeName.text.trim())
            },
            Kirigami.Action {
                text: "Remove"
                icon.name: "edit-delete-symbolic"
                visible: vibeEditor.editing
                onTriggered: vibeEditor.save("", "Removed vibration " + vibeName.text.trim())
            },
            Kirigami.Action {
                text: "Cancel"
                icon.name: "dialog-cancel-symbolic"
                onTriggered: vibeEditor.close()
            }
        ]
    }

    // ============ ADD FILTER (prompt dialog) ============
    Kirigami.PromptDialog {
        id: filterDialog
        title: "Add filter"
        standardButtons: QQC2.Dialog.NoButton

        function openForNew() {
            patternField.text = "";
            actionGroup.action = "block";
            open();
        }

        property string action: actionGroup.action

        ColumnLayout {
            spacing: Kirigami.Units.largeSpacing

            QQC2.Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: "Regex matched on the notification title and body."
            }

            QQC2.TextField {
                id: patternField
                Layout.fillWidth: true
                placeholderText: "Regex pattern"
                font.family: "monospace"
            }

            ColumnLayout {
                id: actionGroup
                spacing: Kirigami.Units.smallSpacing
                property string action: "block"

                QQC2.RadioButton {
                    text: "Block matching"
                    checked: actionGroup.action === "block"
                    onToggled: if (checked) actionGroup.action = "block"
                }
                QQC2.RadioButton {
                    text: "Always allow"
                    checked: actionGroup.action === "allow"
                    onToggled: if (checked) actionGroup.action = "allow"
                }
            }
        }

        customFooterActions: [
            Kirigami.Action {
                text: "Add"
                icon.name: "list-add"
                enabled: patternField.text.trim() !== ""
                onTriggered: {
                    var r = StoandlClient.notifAddFilter(patternField.text.trim(), actionGroup.action);
                    if (r.ok)
                        page.toast("Filter added");
                    else
                        page.toast("Add filter failed: " + (r.tail || r.kind));
                    page.reload();
                    filterDialog.close();
                }
            },
            Kirigami.Action {
                text: "Cancel"
                icon.name: "dialog-cancel-symbolic"
                onTriggered: filterDialog.close()
            }
        ]
    }
}
