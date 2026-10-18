import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// Notifications screen. Master forward toggle + temp-mute + where the app name goes on the watch (with a
// WatchCardPreview), per-app list (each row opens a deeper Kirigami.Dialog), and regex filters. Everything
// is polled/re-fetched in reload() — the interface has no change events, so every mutation re-fetches its
// slice (handoff hard rules).
Kirigami.ScrollablePage {
    id: page
    objectName: "notifications"
    title: "Alerts"   // matches the (shortened) nav tab label

    // --- live snapshots (all re-fetched in reload()) -----------------------
    property bool forward: false           // master "Forward notifications"
    property var apps: []                   // notifList() rows
    property var filters: []                // notifListFilters() rows

    // Master temp-mute state is DERIVED from the re-fetched per-app list — the daemon
    // reflects mute-all into each app's muteLabel and there is no NotifGetMuteAll
    // getter, so this stays correct across reload / per-app mutes / external changes.
    readonly property bool allMuted: page.apps.length > 0 && page.apps.every(function (a) { return a.muted === true; })

    // Where an app's name goes on the watch: notification.app_name's options. `text` is the label GetConfig
    // reports and SetConfig takes, `value` the placement token (WatchCardPreview's, and NotifSetAppName's
    // for the per-app override).
    readonly property var appNamePlacements: [
        { text: "Small line", value: "small" },
        { text: "Subtitle",   value: "subtitle" },
        { text: "Off",        value: "off" }
    ]
    // notification.app_name as a token: the Alerts preview's placement and what an app on "Default"
    // follows. reload() reads it with GetConfig; "" until then (or from a daemon without the key), which
    // hides the row and its preview.
    property string appNameGlobal: ""
    // notification.images, for the per-app images switch's hint; reload() reads it.
    property bool imagesGlobal: true

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    // The label of a placement token ("Small line" for small); "" for one that isn't offered.
    function appNameLabel(token) {
        var i = page.optionIndex(page.appNamePlacements, token);
        return i >= 0 ? page.appNamePlacements[i].text : "";
    }

    // Index of the option whose value is `v` (case-insensitive, like the daemon's TimelineColor.findByName);
    // -1 when none is. `byLabel` also accepts the label: only for GetConfig, which answers a combo with
    // its label. NotifList's colour and placement are values, and matching their labels would pick the
    // wrong colour ("Yellow" is ChromeYellow's label but its own TimelineColor).
    function optionIndex(options, v, byLabel) {
        var s = String(v || "").toLowerCase();
        for (var i = 0; i < options.length; ++i) {
            if (options[i].value.toLowerCase() === s || (byLabel && options[i].text.toLowerCase() === s))
                return i;
        }
        return -1;
    }

    // Asynchronous (one round of parallel reads); the latest call wins.
    function reload() {
        if (!StoandlClient.daemonUp)
            return;
        StoandlClient.fetch(page, [["getSyncStatus"], ["notifList"], ["notifListFilters"], ["getConfig"]], function (r) {
            // Master forward state lives in the sync-status table.
            var ss = r[0];
            var fwd = false;
            for (var i = 0; i < ss.length; ++i) {
                if (ss[i].service === "notifications") { fwd = ss[i].enabled === true; break; }
            }
            page.forward = fwd;
            // Set, not only bound: FormSwitchDelegate drops its `checked` binding on the first change, and
            // this page is kept across tab visits (Main.qml), so a change made elsewhere (Settings → Sync,
            // the CLI) or a refused toggle would otherwise leave the switch showing the old state.
            forwardSwitch.checked = fwd;
            page.apps = r[1];
            page.filters = r[2];
            // The combo is set imperatively, not bound, like the per-app combos (see appDialog.showChoices()).
            var values = (r[3] && r[3].values) ? r[3].values : {};
            var g = page.optionIndex(page.appNamePlacements, values["notification.app_name"], true);
            page.appNameGlobal = g >= 0 ? page.appNamePlacements[g].value : "";
            var img = values["notification.images"];
            page.imagesGlobal = img === undefined || String(img).toLowerCase() !== "false";
            appNameGlobalCombo.currentIndex = g;
        });
    }

    // Kept while another tab shows (Main.qml): re-read when it comes back.
    function refreshOnShow() { page.reload(); }

    // The same key as Settings → Daemon configuration's row, written as its label. The preview follows
    // the pick before the write lands.
    function setAppNameGlobal(index) {
        var o = page.appNamePlacements[index];
        page.appNameGlobal = o.value;
        var r = StoandlClient.setConfig("notification.app_name", o.text);
        if (r.ok)
            page.toast("App name · " + o.text);
        else
            page.toast("App name: " + (r.tail || r.kind));
        page.reload();
    }

    // Master mute (30m / 1h / today / never). Re-reads the per-app list since the
    // daemon reflects mute-all in each app's state.
    function muteAll(spec) {
        var r = StoandlClient.notifSetMuteAll(spec);
        if (r.ok) {
            page.toast(spec === "never" ? "Notifications resumed"
                     : spec === "today" ? "Muted for the rest of today"
                     : "Muted for " + spec);
        } else {
            page.toast("Mute failed: " + (r.tail || r.kind));
        }
        page.reload();
    }

    Connections {
        target: StoandlClient
        enabled: page.visible
        function onDaemonUpChanged() { if (StoandlClient.daemonUp) page.reload(); }
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
    // control on this page that goes through SendTestNotification, the app-name choice with its preview
    // and the per-app dialog, which only a click reaches.
    function smokeExercise() {
        // Guarded like the action itself: with the daemon down the button is disabled, so firing it
        // here would exercise a path a user cannot reach and log a misleading D-Bus error.
        if (StoandlClient.daemonUp)
            page.sendTest();
        // The global app name: the preview for each placement (without the write), then the stored
        // value written back unchanged (a no-op, also against a real daemon).
        var stored = page.appNameGlobal;
        if (StoandlClient.daemonUp && stored !== "") {
            for (var i = 0; i < page.appNamePlacements.length; ++i) {
                page.appNameGlobal = page.appNamePlacements[i].value;
                page.smokePreview(alertsPreview);
            }
            page.appNameGlobal = stored;
            var label = page.appNameLabel(stored);
            var g = StoandlClient.setConfig("notification.app_name", label);
            console.log("stoandl-smoke: notif app name global = " + label + " (" + g.kind + ")");
            page.reload();
        }
        // The per-app dialog, for an app with an app-name override if there is one: its preselection
        // comes from NotifList's 7th column, and the same value goes back through NotifSetAppName
        // (a no-op change, also against a real daemon). Its preview shows that override, then —
        // without the write — "Default", which follows the global placement.
        var a = page.apps.find(function (x) { return x.appNamePlacement !== ""; }) || page.apps[0];
        if (StoandlClient.daemonUp && a) {
            appDialog.openFor(a);
            page.smokePreview(dialogPreview);
            var r = StoandlClient.notifSetAppName(a.name, a.appNamePlacement || "default");
            console.log("stoandl-smoke: notif app name: " + a.name + " = " + appNameCombo.currentText
                        + " (" + r.kind + ")");
            appNameCombo.currentIndex = 0;
            page.smokePreview(dialogPreview);
            appDialog.close();
        }
        console.log("stoandl-smoke: exercised notifications page");
    }

    actions: [
        Kirigami.Action {
            icon.name: "mail-send-symbolic"
            text: "Send test"
            enabled: StoandlClient.daemonUp
            onTriggered: page.sendTest()
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

        // ============ MASTER + TEMP MUTE ============
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp
            title: "Forwarding"
        }

        FormCard.FormCard {
            visible: StoandlClient.daemonUp

            FormCard.FormSwitchDelegate {
                id: forwardSwitch
                text: "Forward notifications"
                description: "Send phone notifications to the watch"
                checked: page.forward
                onToggled: {
                    var r = StoandlClient.setSyncEnabled("notifications", checked);
                    if (r.ok) {
                        page.toast(checked ? "Notifications on" : "Notifications paused");
                    } else {
                        page.toast("Could not change forwarding: " + (r.tail || r.kind));
                    }
                    page.reload();   // re-read master state after mutation
                }
            }

            FormCard.FormDelegateSeparator {}

            // Temporary mute (30m / 1h / today) or Resume.
            FormCard.AbstractFormDelegate {
                Layout.fillWidth: true
                background: null
                contentItem: ColumnLayout {
                    spacing: Kirigami.Units.smallSpacing
                    QQC2.Label {
                        Layout.fillWidth: true
                        text: page.allMuted ? "Muted temporarily" : "Mute temporarily"
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

            FormCard.FormDelegateSeparator { visible: appNameGlobalCombo.visible }

            // notification.app_name (also a row in Settings → Daemon configuration); apps override it in
            // their own dialog.
            FormCard.FormComboBoxDelegate {
                id: appNameGlobalCombo
                visible: page.appNameGlobal !== ""
                text: "App name on the watch"
                description: "Where an app's name goes on a notification. Each app can override it."
                textRole: "text"
                valueRole: "value"
                model: page.appNamePlacements
                onActivated: (index) => page.setAppNameGlobal(index)
            }

            WatchCardPreview {
                id: alertsPreview
                visible: appNameGlobalCombo.visible
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: Kirigami.Units.smallSpacing
                Layout.bottomMargin: Kirigami.Units.largeSpacing
                appName: "NeoChat"
                placement: page.appNameGlobal
            }
        }

        // ============ PER-APP ============
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp && page.apps.length > 0
            title: "Per-app"
        }

        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.apps.length > 0

            Repeater {
                model: page.apps

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
                                text: appRow.modelData.muted ? "Muted"
                                                            : "Vibration · " + appRow.modelData.vibe
                                elide: Text.ElideRight
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                            }
                        }

                        // On = NOT muted. Toggling consumes the click so the row
                        // onClicked (open deeper view) does not also fire.
                        QQC2.Switch {
                            checked: !appRow.modelData.muted
                            onToggled: {
                                var r = StoandlClient.notifSetMute(appRow.modelData.name,
                                                                   checked ? "never" : "always");
                                if (!r.ok)
                                    page.toast("Mute failed: " + (r.tail || r.kind));
                                page.reload();
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
                visible: page.filters.length === 0
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
                            onClicked: {
                                var r = StoandlClient.notifRemoveFilter(filterRow.modelData.pattern);
                                if (!r.ok)
                                    page.toast("Remove failed: " + (r.tail || r.kind));
                                page.reload();
                            }
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

        FormCard.FormSectionText {
            visible: StoandlClient.daemonUp
            text: "This screen covers notifications forwarded from desktop apps. stoandl's own alerts — pairing problems, a Bluetooth scan blocking reconnects, an extension that needs setup, firmware updates — are under Settings → Daemon configuration."
        }
    }

    // ============ PER-APP DEEPER VIEW (dialog) ============
    Kirigami.Dialog {
        id: appDialog

        property var app: ({})
        property string appName: ""

        // Vibrations and icons as the daemon advertises them (NotifStyleChoices), so a pick is always
        // something NotifSetStyle accepts; "default" drops the override. Read on open.
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

        title: appName
        preferredWidth: Kirigami.Units.gridUnit * 24
        // Taller than most windows with the preview, so it scrolls. Kirigami.Dialog slides in from 2 gridUnits
        // lower; at the default maximum that runs past the window's bottom, the popup is squeezed to fit, which
        // moves it again (a binding loop on y and a jumpy open). Leave room for the slide.
        maximumHeight: absoluteMaximumHeight - Kirigami.Units.gridUnit * 4
        standardButtons: QQC2.Dialog.Close
        showCloseButton: true

        readonly property bool muted: appDialog.app && appDialog.app.muted === true

        function openFor(row) {
            var choices = StoandlClient.notifStyleChoices();
            appDialog.vibes = [{ text: "Default", value: "default" }].concat(choices.vibes || []);
            appDialog.iconOptions = [{ text: "Default", value: "default" }].concat(choices.icons || []);
            appDialog.app = row;
            appDialog.appName = row.name;
            appDialog.showChoices();
            appDialog.open();
        }

        // After a per-app mutation, refresh the page list and re-seed our copy.
        function refreshApp() {
            page.reload();
            var rows = StoandlClient.notifList();
            for (var i = 0; i < rows.length; ++i) {
                if (rows[i].name === appDialog.appName) { appDialog.app = rows[i]; break; }
            }
            appDialog.showChoices();
        }

        // The app's stored colour, icon and app-name placement into their combos (the preview follows both; a
        // colour name not offered here shows as Default). Set imperatively, not bound: the mobile selection
        // dialog assigns currentIndex itself, which would drop a binding and leave the next app's dialog
        // showing this one's choice.
        function showChoices() {
            colorCombo.currentIndex = Math.max(0, page.optionIndex(appDialog.colorOptions, appDialog.app && appDialog.app.color));
            iconCombo.currentIndex = Math.max(0, page.optionIndex(appDialog.iconOptions, appDialog.app && appDialog.app.icon));
            appNameCombo.currentIndex = Math.max(0, page.optionIndex(appDialog.appNameOptions,
                                                                     appDialog.app && appDialog.app.appNamePlacement));
            imagesSwitch.checked = !(appDialog.app && appDialog.app.imagesOff === true);
        }

        ColumnLayout {
            spacing: 0
            Layout.preferredWidth: Kirigami.Units.gridUnit * 24

            // --- on/off + temp mute ---
            FormCard.AbstractFormDelegate {
                Layout.fillWidth: true
                background: null
                contentItem: ColumnLayout {
                    spacing: Kirigami.Units.smallSpacing

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.largeSpacing
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            QQC2.Label { text: "Notifications" }
                            QQC2.Label {
                                text: appDialog.muted ? "Off" : "Forwarded to watch"
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                            }
                        }
                        QQC2.Switch {
                            checked: !appDialog.muted
                            onToggled: {
                                var r = StoandlClient.notifSetMute(appDialog.appName,
                                                                   checked ? "never" : "always");
                                if (!r.ok)
                                    page.toast("Mute failed: " + (r.tail || r.kind));
                                appDialog.refreshApp();
                            }
                        }
                    }

                    QQC2.Label {
                        Layout.fillWidth: true
                        Layout.topMargin: Kirigami.Units.smallSpacing
                        text: appDialog.muted ? "Muted" : "Mute temporarily"
                        font: Kirigami.Theme.smallFont
                        opacity: 0.7
                    }
                    RowLayout {
                        spacing: Kirigami.Units.smallSpacing
                        QQC2.Button {
                            visible: appDialog.muted
                            text: "Resume"
                            icon.name: "media-playback-start-symbolic"
                            onClicked: {
                                var r = StoandlClient.notifSetMute(appDialog.appName, "never");
                                if (!r.ok) page.toast("Resume failed: " + (r.tail || r.kind));
                                appDialog.refreshApp();
                            }
                        }
                        QQC2.Button {
                            visible: !appDialog.muted
                            text: "30 min"
                            onClicked: {
                                StoandlClient.notifSetMute(appDialog.appName, "30m");
                                appDialog.refreshApp();
                            }
                        }
                        QQC2.Button {
                            visible: !appDialog.muted
                            text: "1 hr"
                            onClicked: {
                                StoandlClient.notifSetMute(appDialog.appName, "1h");
                                appDialog.refreshApp();
                            }
                        }
                        QQC2.Button {
                            visible: !appDialog.muted
                            text: "Today"
                            onClicked: {
                                StoandlClient.notifSetMute(appDialog.appName, "today");
                                appDialog.refreshApp();
                            }
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
                    readonly property bool chosen: appDialog.app
                        && (appDialog.app.vibe || "default").toLowerCase() === modelData.value.toLowerCase()
                    Layout.fillWidth: true
                    onClicked: {
                        var r = StoandlClient.notifSetStyle(appDialog.appName, "", "", vibeRow.modelData.value);
                        if (r.ok)
                            page.toast("Vibration · " + vibeRow.modelData.text);
                        else
                            page.toast("Vibration: " + (r.tail || r.kind));
                        appDialog.refreshApp();
                    }
                    contentItem: RowLayout {
                        spacing: Kirigami.Units.largeSpacing
                        Kirigami.Icon {
                            source: "audio-volume-high-symbolic"
                            color: vibeRow.chosen ? Kirigami.Theme.highlightColor : Kirigami.Theme.textColor
                            implicitWidth: Kirigami.Units.iconSizes.smallMedium
                            implicitHeight: Kirigami.Units.iconSizes.smallMedium
                        }
                        QQC2.Label { text: vibeRow.modelData.text; Layout.fillWidth: true; elide: Text.ElideRight }
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

            Kirigami.Separator { Layout.fillWidth: true }

            // --- options: custom icon (preselected by showChoices(), so only a user's pick writes) ---
            FormCard.FormComboBoxDelegate {
                id: iconCombo
                Layout.fillWidth: true
                text: "Custom icon"
                description: "Glyph shown on the watch"
                textRole: "text"
                valueRole: "value"
                model: appDialog.iconOptions
                onActivated: (index) => {
                    var o = appDialog.iconOptions[index];
                    var r = StoandlClient.notifSetStyle(appDialog.appName, "", o.value, "");
                    if (r.ok)
                        page.toast("Icon · " + o.text);
                    else
                        page.toast("Icon: " + (r.tail || r.kind));
                    appDialog.refreshApp();
                }
            }

            // --- options: accent color (preselected by showChoices(), so only a user's pick writes) ---
            FormCard.FormComboBoxDelegate {
                id: colorCombo
                Layout.fillWidth: true
                text: "Notification color"
                description: "Accent colour on the watch"
                textRole: "text"
                valueRole: "value"
                model: appDialog.colorOptions
                onActivated: (index) => {
                    var o = appDialog.colorOptions[index];
                    var r = StoandlClient.notifSetStyle(appDialog.appName, o.value, "", "");
                    if (r.ok)
                        page.toast("Color · " + o.text);
                    else
                        page.toast("Color: " + (r.tail || r.kind));
                    appDialog.refreshApp();
                }
            }

            // --- options: where the app's name goes on the watch ---
            FormCard.FormComboBoxDelegate {
                id: appNameCombo
                Layout.fillWidth: true
                text: "App name"
                description: "Default follows the Alerts page"
                             + (page.appNameGlobal !== "" ? ", now " + page.appNameLabel(page.appNameGlobal) : "") + "."
                textRole: "text"
                valueRole: "value"
                model: appDialog.appNameOptions
                onActivated: (index) => {
                    var o = appDialog.appNameOptions[index];
                    var r = StoandlClient.notifSetAppName(appDialog.appName, o.value);
                    if (r.ok)
                        page.toast("App name · " + o.text);
                    else
                        page.toast("App name: " + (r.tail || r.kind));
                    appDialog.refreshApp();
                }
            }

            // The official app's per-app images switch; on follows notification.images.
            FormCard.FormSwitchDelegate {
                id: imagesSwitch
                Layout.fillWidth: true
                text: "Send images"
                description: page.imagesGlobal ? "Pictures this app attaches, on watches that show them."
                                               : "Pictures are off for every app (Settings → Daemon configuration → Pictures on the watch)."
                onToggled: {
                    var r = StoandlClient.notifSetImages(appDialog.appName, checked ? "on" : "off");
                    if (r.ok)
                        page.toast(checked ? "Images on" : "Images off");
                    else
                        page.toast("Images: " + (r.tail || r.kind));
                    appDialog.refreshApp();
                }
            }

            // This app's card as the colour and app-name picks put it on the watch.
            WatchCardPreview {
                id: dialogPreview
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: Kirigami.Units.smallSpacing
                Layout.bottomMargin: Kirigami.Units.largeSpacing
                appName: appDialog.appName
                // "Default" follows the global placement; the daemon's default before that is read.
                placement: appNameCombo.currentValue && appNameCombo.currentValue !== "default"
                           ? appNameCombo.currentValue : (page.appNameGlobal || "small")
                accent: colorCombo.currentIndex >= 0 ? appDialog.colorOptions[colorCombo.currentIndex].swatch : ""
            }
        }
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
