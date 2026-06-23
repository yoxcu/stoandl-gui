import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

Kirigami.ScrollablePage {
    id: page
    objectName: "watch"
    // No title text — the bottom navigation already shows the section. The action toolbar (header on
    // desktop / footer on mobile) and pushed sub-page headers stay as Kirigami renders them.
    title: ""
    Accessible.name: "Watch"

    // Latest ListWatches snapshot (parsed in C++) + the connected row, if any.
    property var watches: []
    property var connectedWatch: null

    // Firmware: the CheckFirmware result drives the update banner; the inline
    // flash poll (UpdateFirmware -> FirmwareStatus) lives here now — no detour
    // to a separate screen (handoff §4d).
    property var fwInfo: null
    property string fwPhase: ""     // "" = idle; else downloading/waiting/inprogress/notready
    property int fwPercent: -1
    readonly property bool fwBusy: fwPhase !== ""
    readonly property bool updateAvailable: fwInfo && fwInfo.kind === "ok" && fwInfo.updateAvailable === true

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    function applyWatches(rows) {
        page.watches = rows;
        var found = null;
        for (var i = 0; i < rows.length; ++i) {
            if (rows[i].connected) { found = rows[i]; break; }
        }
        page.connectedWatch = found;
    }

    function checkFirmware() {
        if (StoandlClient.daemonUp)
            page.fwInfo = StoandlClient.checkFirmware();
    }

    function connectTo(name) {
        var r = StoandlClient.connectWatch(name);
        if (!r.ok)
            page.toast("Connect failed: " + (r.tail || r.kind));
        StoandlClient.refreshWatches(); // re-fetch after mutation
    }

    function stateColor(state) {
        if (state === "connected")  return Kirigami.Theme.positiveTextColor;
        if (state === "connecting") return Kirigami.Theme.neutralTextColor;
        return Kirigami.Theme.disabledTextColor;
    }

    function transportLabel(t) {
        if (t === "classic") return "Bluetooth Classic";
        if (t === "ble")     return "Bluetooth LE";
        return t;
    }

    function fwPhaseLabel() {
        if (fwPhase === "downloading") return "Downloading firmware…";
        if (fwPhase === "waiting")     return "Preparing…";
        if (fwPhase === "inprogress")  return "Flashing… " + (fwPercent >= 0 ? fwPercent + "%" : "");
        if (fwPhase === "notready")    return "Waiting for the watch…";
        return "Working…";
    }

    Connections {
        target: StoandlClient
        function onWatchesChanged(rows) { page.applyWatches(rows); }
        function onPairStatus(kind, msg) { pairDialog.handleStatus(kind, msg); }
        function onFindWatchResult(ok) {
            page.toast(ok ? "Ringing watch…" : "No watch ready to ring");
        }
        function onFirmwareStatus(kind, percent, detail) {
            if (kind === "success") { page.toast("Firmware flashed — watch is rebooting"); page.fwPhase = ""; page.fwPercent = -1; page.fwInfo = null; }
            else if (kind === "failed") { page.toast("Flash failed: " + detail); page.fwPhase = ""; page.fwPercent = -1; }
            else if (kind === "timeout") { page.toast("Flash timed out"); page.fwPhase = ""; page.fwPercent = -1; }
            else { page.fwPhase = kind; page.fwPercent = percent; }
        }
        function onDaemonUpChanged() {
            if (StoandlClient.daemonUp) {
                StoandlClient.refreshWatches();
                page.checkFirmware();
            }
        }
    }

    // 20 s safety-net poll runs only while this page is alive (live updates arrive via
    // the WatchesChanged signal; this is the BluetoothStatus carrier + missed-signal fallback).
    Component.onCompleted: { StoandlClient.startWatchPoll(); page.checkFirmware(); }
    Component.onDestruction: StoandlClient.stopWatchPoll()

    // Page actions: header (desktop) / footer toolbar (mobile). NOT a Material FAB.
    actions: [
        Kirigami.Action {
            icon.name: "list-add"
            text: "Pair new watch"
            enabled: StoandlClient.daemonUp && StoandlClient.bluetoothOn
            onTriggered: pairDialog.openForPair()
        },
        Kirigami.Action {
            icon.name: "find-location-symbolic"
            text: "Ring watch"
            enabled: StoandlClient.daemonUp && page.connectedWatch !== null
            onTriggered: StoandlClient.findWatch()
        },
        Kirigami.Action {
            icon.name: "view-refresh-symbolic"
            text: "Sync now"
            enabled: StoandlClient.daemonUp
            onTriggered: { StoandlClient.refreshWatches(); page.checkFirmware(); page.toast("Refreshed"); }
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

        // --- Bluetooth-off state (daemon up, adapter off / rfkill / airplane) ---
        // The daemon detects this (adapter Powered + org.bluez.GattManager1) and reconnects on its
        // own when BT returns; we just surface it instead of an empty/"pair a watch" screen.
        Kirigami.InlineMessage {
            visible: StoandlClient.daemonUp && !StoandlClient.bluetoothOn
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.largeSpacing
            Layout.leftMargin: Kirigami.Units.largeSpacing
            Layout.rightMargin: Kirigami.Units.largeSpacing
            type: Kirigami.MessageType.Warning
            icon.source: "network-bluetooth-inactive-symbolic"
            text: "Bluetooth is off — turn it on to connect your Pebble. The daemon reconnects automatically."
        }

        // --- no-watch (notready) empty state -------------------------------
        Kirigami.PlaceholderMessage {
            visible: StoandlClient.daemonUp && StoandlClient.bluetoothOn && page.connectedWatch === null && page.watches.length === 0
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
            icon.name: "chronometer-symbolic"
            text: "No watch connected"
            explanation: "Pair a Pebble to get started. The daemon is running and ready."
            helpfulAction: Kirigami.Action {
                icon.name: "list-add"
                text: "Pair new watch"
                onTriggered: pairDialog.openForPair()
            }
        }

        // --- firmware: flashing-in-progress --------------------------------
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp && page.fwBusy
            title: "Updating firmware"
        }
        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.fwBusy

            FormCard.FormTextDelegate { text: page.fwPhaseLabel() }
            QQC2.ProgressBar {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.largeSpacing
                from: 0; to: 100
                value: page.fwPercent
                indeterminate: page.fwPercent < 0
            }
        }

        // --- firmware: update-available banner -----------------------------
        Kirigami.InlineMessage {
            visible: StoandlClient.daemonUp && !page.fwBusy && page.updateAvailable
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.largeSpacing
            Layout.leftMargin: Kirigami.Units.largeSpacing
            Layout.rightMargin: Kirigami.Units.largeSpacing
            type: Kirigami.MessageType.Information
            icon.source: "update-low-symbolic"
            text: page.fwInfo ? ("PebbleOS " + page.fwInfo.latest + " available") : ""
            actions: [
                Kirigami.Action {
                    icon.name: "install-symbolic"
                    text: "Update now"
                    onTriggered: {
                        var r = StoandlClient.updateFirmware();
                        if (r.ok) page.toast("Firmware flash started…");
                        else if (r.kind === "uptodate") page.toast("Already up to date");
                        else page.toast("Firmware: " + (r.tail !== "" ? r.tail : r.kind));
                    }
                },
                Kirigami.Action {
                    icon.name: "globe-symbolic"
                    text: "What’s new"
                    enabled: page.fwInfo && page.fwInfo.changelogUrl !== ""
                    onTriggered: Qt.openUrlExternally(page.fwInfo.changelogUrl)
                }
            ]
        }

        // --- active-watch hero (tappable -> Watch details dialog) ----------
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp && page.connectedWatch !== null
            title: "Active watch"
        }

        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.connectedWatch !== null

            FormCard.AbstractFormDelegate {
                onClicked: detailsDialog.openFor()

                contentItem: RowLayout {
                    spacing: Kirigami.Units.largeSpacing

                    Kirigami.Icon {
                        source: "chronometer-symbolic"
                        implicitWidth: Kirigami.Units.iconSizes.huge
                        implicitHeight: Kirigami.Units.iconSizes.huge
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        Kirigami.Heading {
                            level: 2
                            text: page.connectedWatch ? page.connectedWatch.name : ""
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                        StatusChip {
                            label: page.connectedWatch && page.connectedWatch.transport !== ""
                                   ? "Connected · " + page.transportLabel(page.connectedWatch.transport)
                                   : "Connected"
                            tint: Kirigami.Theme.positiveTextColor
                        }
                    }

                    ColumnLayout {
                        visible: page.connectedWatch && page.connectedWatch.battery !== ""
                        spacing: 0
                        Layout.alignment: Qt.AlignVCenter
                        RowLayout {
                            Layout.alignment: Qt.AlignRight
                            Kirigami.Icon {
                                source: "battery-symbolic"
                                implicitWidth: Kirigami.Units.iconSizes.small
                                implicitHeight: Kirigami.Units.iconSizes.small
                            }
                            Kirigami.Heading {
                                level: 3
                                text: (page.connectedWatch ? page.connectedWatch.battery : "") + "%"
                            }
                        }
                        QQC2.Label {
                            text: "battery"
                            Layout.alignment: Qt.AlignRight
                            font: Kirigami.Theme.smallFont
                            opacity: 0.7
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

        // --- known watches (inline actions, no kebab) ----------------------
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp && page.watches.length > 0
            title: "Known watches"
        }

        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.watches.length > 0

            Repeater {
                model: page.watches

                delegate: FormCard.AbstractFormDelegate {
                    id: watchRow
                    required property var modelData

                    // Tap connects (unless already active).
                    onClicked: {
                        if (!modelData.connected)
                            page.connectTo(modelData.name);
                    }

                    contentItem: RowLayout {
                        spacing: Kirigami.Units.largeSpacing

                        Kirigami.Icon {
                            source: "chronometer-symbolic"
                            color: watchRow.modelData.connected ? Kirigami.Theme.positiveTextColor
                                                                : Kirigami.Theme.disabledTextColor
                            implicitWidth: Kirigami.Units.iconSizes.medium
                            implicitHeight: Kirigami.Units.iconSizes.medium
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: watchRow.modelData.name
                                elide: Text.ElideRight
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: watchRow.modelData.connected
                                      ? (page.transportLabel(watchRow.modelData.transport)
                                         + (watchRow.modelData.battery !== "" ? " · " + watchRow.modelData.battery + "%" : ""))
                                      : "disconnected"
                                elide: Text.ElideRight
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                            }
                        }

                        StatusChip {
                            visible: watchRow.modelData.connected
                            label: "active"
                            tint: Kirigami.Theme.positiveTextColor
                        }

                        QQC2.Button {
                            visible: !watchRow.modelData.connected
                            text: "Connect"
                            onClicked: page.connectTo(watchRow.modelData.name)
                        }

                        QQC2.ToolButton {
                            icon.name: "edit-delete-remove-symbolic"
                            display: QQC2.AbstractButton.IconOnly
                            QQC2.ToolTip.text: "Forget watch"
                            QQC2.ToolTip.visible: hovered
                            onClicked: forgetDialog.openFor(watchRow.modelData.name)
                        }
                    }
                }
            }
        }
    }

    // --- Watch details dialog (§4d) ----------------------------------------
    WatchDetailsDialog {
        id: detailsDialog
        onForgetRequested: function(name) { forgetDialog.openFor(name); }
    }

    // --- pairing dialog (Pair + Repair) ------------------------------------
    Kirigami.PromptDialog {
        id: pairDialog
        title: "Pair watch"
        standardButtons: QQC2.Dialog.Cancel
        showCloseButton: true

        property string statusKind: ""
        property string statusMsg: ""
        property string code: ""

        function openForPair() {
            title = "Pair watch";
            statusKind = "";
            code = "";
            statusMsg = "Opening pairing window…";
            open();
            var r = StoandlClient.pair();
            if (r.ok) {
                StoandlClient.startPairPoll();
            } else {
                statusKind = r.kind;
                statusMsg = r.tail || ("Could not start pairing (" + r.kind + ")");
            }
        }

        function openForRepair(name) {
            title = "Re-pair " + name;
            statusKind = "";
            code = "";
            statusMsg = "Re-opening pairing window…";
            open();
            var r = StoandlClient.repair(name);
            if (r.ok) {
                StoandlClient.startPairPoll();
            } else {
                statusKind = r.kind;
                statusMsg = r.tail || ("Could not start re-pairing (" + r.kind + ")");
            }
        }

        function handleStatus(kind, msg) {
            statusKind = kind;
            // confirm:<code> — show the code and the Accept/Decline buttons; the user verifies it
            // matches the code on the watch before accepting.
            if (kind === "confirm") {
                code = msg;
                statusMsg = "Does this code match the one shown on the watch?";
                return;
            }
            statusMsg = msg !== "" ? msg : kind;
            if (kind === "ok") {
                page.toast("Watch paired");
                StoandlClient.refreshWatches();
                close();
            }
        }

        onClosed: StoandlClient.stopPairPoll()

        ColumnLayout {
            spacing: Kirigami.Units.largeSpacing

            QQC2.Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: pairDialog.statusKind === "confirm"
                    ? "Verify this code matches the one shown on the watch, then Accept."
                    : "Put the watch in pairing mode."
            }

            QQC2.Label {
                visible: pairDialog.statusKind === "confirm"
                Layout.alignment: Qt.AlignHCenter
                text: pairDialog.code
                font.family: "monospace"
                font.bold: true
                font.pointSize: Kirigami.Theme.defaultFont.pointSize * 2
            }

            RowLayout {
                spacing: Kirigami.Units.largeSpacing
                QQC2.BusyIndicator {
                    visible: pairDialog.statusKind === "" || pairDialog.statusKind === "pending"
                    running: visible
                    implicitWidth: Kirigami.Units.iconSizes.medium
                    implicitHeight: Kirigami.Units.iconSizes.medium
                }
                Kirigami.Icon {
                    visible: pairDialog.statusKind === "error" || pairDialog.statusKind === "timeout"
                    source: "dialog-error-symbolic"
                    implicitWidth: Kirigami.Units.iconSizes.medium
                    implicitHeight: Kirigami.Units.iconSizes.medium
                }
                QQC2.Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: pairDialog.statusMsg
                }
            }

            // Numeric-comparison Accept/Decline (only while a code is awaiting a decision).
            RowLayout {
                visible: pairDialog.statusKind === "confirm"
                Layout.fillWidth: true
                QQC2.Button {
                    text: "Decline"
                    icon.name: "dialog-cancel-symbolic"
                    onClicked: {
                        StoandlClient.confirmPairing(false);
                        pairDialog.statusKind = "pending";
                        pairDialog.statusMsg = "Declining…";
                    }
                }
                Item { Layout.fillWidth: true }
                QQC2.Button {
                    text: "Accept"
                    icon.name: "dialog-ok-symbolic"
                    highlighted: true
                    onClicked: {
                        StoandlClient.confirmPairing(true);
                        pairDialog.statusKind = "pending";
                        pairDialog.statusMsg = "Completing pairing…";
                    }
                }
            }
        }
    }

    // --- forget (unpair) confirmation --------------------------------------
    Kirigami.PromptDialog {
        id: forgetDialog
        title: "Forget watch"
        standardButtons: QQC2.Dialog.NoButton

        property string watchName: ""

        function openFor(name) {
            watchName = name;
            subtitle = "Forget \"" + name + "\"? This unpairs the watch from this host. You can pair it again later.";
            open();
        }

        customFooterActions: [
            Kirigami.Action {
                text: "Forget"
                icon.name: "edit-delete-remove-symbolic"
                onTriggered: {
                    var r = StoandlClient.unpair(forgetDialog.watchName);
                    if (!r.ok)
                        page.toast("Unpair failed: " + (r.tail || r.kind));
                    StoandlClient.refreshWatches();
                    forgetDialog.close();
                }
            },
            Kirigami.Action {
                text: "Cancel"
                icon.name: "dialog-cancel-symbolic"
                onTriggered: forgetDialog.close()
            }
        ]
    }
}
