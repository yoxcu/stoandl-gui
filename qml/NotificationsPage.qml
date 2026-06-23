import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// Notifications screen. Master forward toggle + temp-mute, per-app list (each
// row opens a deeper Kirigami.Dialog), and regex filters. Everything is
// polled/re-fetched in reload() — the interface has no change events, so every
// mutation re-fetches its slice (handoff hard rules).
Kirigami.ScrollablePage {
    id: page
    objectName: "notifications"
    title: "Notifications"
    // No page-title header (the bottom nav shows the section); the action moves to an inline toolbar.
    globalToolBarStyle: Kirigami.ApplicationHeaderStyle.None

    // --- live snapshots (all re-fetched in reload()) -----------------------
    property bool forward: false           // master "Forward notifications"
    property var apps: []                   // notifList() rows
    property var filters: []                // notifListFilters() rows

    // Master temp-mute state is DERIVED from the re-fetched per-app list — the daemon
    // reflects mute-all into each app's muteLabel and there is no NotifGetMuteAll
    // getter, so this stays correct across reload / per-app mutes / external changes.
    readonly property bool allMuted: page.apps.length > 0 && page.apps.every(function (a) { return a.muted === true; })

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    function reload() {
        if (!StoandlClient.daemonUp)
            return;
        // Master forward state lives in the sync-status table.
        var ss = StoandlClient.getSyncStatus();
        var fwd = false;
        for (var i = 0; i < ss.length; ++i) {
            if (ss[i].service === "notifications") { fwd = ss[i].enabled === true; break; }
        }
        page.forward = fwd;
        page.apps = StoandlClient.notifList();
        page.filters = StoandlClient.notifListFilters();
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
        function onDaemonUpChanged() { if (StoandlClient.daemonUp) page.reload(); }
    }

    Component.onCompleted: page.reload()

    // Page action, rendered in an inline toolbar (the page header is hidden).
    readonly property list<Kirigami.Action> pageActions: [
        Kirigami.Action {
            icon.name: "list-add"
            text: "Add filter"
            enabled: StoandlClient.daemonUp
            onTriggered: filterDialog.openForNew()
        }
    ]

    ColumnLayout {
        spacing: 0

        Kirigami.ActionToolBar {
            visible: StoandlClient.daemonUp
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.smallSpacing
            alignment: Qt.AlignRight
            actions: page.pageActions
        }

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
    }

    // ============ PER-APP DEEPER VIEW (dialog) ============
    Kirigami.Dialog {
        id: appDialog

        property var app: ({})
        property string appName: ""

        // Fixed sets (handoff spec).
        readonly property var vibes: ["Standard", "Double", "Long", "Subtle", "Heartbeat"]
        readonly property var iconOptions: ["Default", "Bell", "Calendar", "Chat"]

        title: appName
        preferredWidth: Kirigami.Units.gridUnit * 24
        standardButtons: QQC2.Dialog.Close
        showCloseButton: true

        readonly property bool muted: appDialog.app && appDialog.app.muted === true

        function openFor(row) {
            appDialog.app = row;
            appDialog.appName = row.name;
            appDialog.open();
        }

        // After a per-app mutation, refresh the page list and re-seed our copy.
        function refreshApp() {
            page.reload();
            var rows = StoandlClient.notifList();
            for (var i = 0; i < rows.length; ++i) {
                if (rows[i].name === appDialog.appName) { appDialog.app = rows[i]; break; }
            }
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
                    required property string modelData
                    Layout.fillWidth: true
                    onClicked: {
                        var r = StoandlClient.notifSetStyle(appDialog.appName, "", "", vibeRow.modelData);
                        if (r.kind === "ok" || r.ok)
                            page.toast("Vibration · " + vibeRow.modelData);
                        else
                            page.toast("Vibration: " + (r.tail || r.kind));
                        appDialog.refreshApp();
                    }
                    contentItem: RowLayout {
                        spacing: Kirigami.Units.largeSpacing
                        Kirigami.Icon {
                            source: "audio-volume-high-symbolic"
                            color: (appDialog.app && appDialog.app.vibe === vibeRow.modelData)
                                   ? Kirigami.Theme.highlightColor : Kirigami.Theme.textColor
                            implicitWidth: Kirigami.Units.iconSizes.smallMedium
                            implicitHeight: Kirigami.Units.iconSizes.smallMedium
                        }
                        QQC2.Label { text: vibeRow.modelData; Layout.fillWidth: true }
                        Kirigami.Icon {
                            visible: appDialog.app && appDialog.app.vibe === vibeRow.modelData
                            source: "checkmark-symbolic"
                            color: Kirigami.Theme.highlightColor
                            implicitWidth: Kirigami.Units.iconSizes.small
                            implicitHeight: Kirigami.Units.iconSizes.small
                        }
                    }
                }
            }

            Kirigami.Separator { Layout.fillWidth: true }

            // --- options: custom icon ---
            FormCard.FormComboBoxDelegate {
                Layout.fillWidth: true
                text: "Custom icon"
                description: "Glyph shown on the watch"
                model: appDialog.iconOptions
                currentIndex: 0
                onCurrentValueChanged: {
                    if (!appDialog.visible)
                        return;
                    var r = StoandlClient.notifSetStyle(appDialog.appName, "", currentValue, "");
                    if (r.kind === "ok" || r.ok)
                        page.toast("Icon · " + currentValue);
                    else
                        page.toast("Icon: " + (r.tail || r.kind));
                    appDialog.refreshApp();
                }
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
