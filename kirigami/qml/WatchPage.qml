import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

Kirigami.ScrollablePage {
    id: page
    objectName: "watch"
    title: "Watch"

    // Latest ListWatches snapshot (parsed in C++) + the connected row, if any.
    property var watches: []
    property var connectedWatch: null

    // Firmware: the CheckFirmware result drives the update banner; the inline
    // flash poll (UpdateFirmware -> FirmwareStatus) lives here now — no detour
    // to a separate screen (handoff §4d). The check itself is asynchronous and cached in
    // StoandlClient (it can take seconds daemon-side), so this page never waits for it.
    readonly property var fwInfo: StoandlClient.firmwareInfo
    property string fwPhase: ""     // "" = idle; else downloading/waiting/inprogress/notready/prf
    property int fwPercent: -1
    property string fwDetail: ""    // prf: the version the watch is being downgraded to
    readonly property bool fwBusy: fwPhase !== ""
    readonly property bool updateAvailable: fwInfo.kind === "ok" && fwInfo.updateAvailable === true
    // LinkPause: the user's Disconnect, and/or the Quiet Time pause (power.quiet_time_link_off).
    readonly property bool pausedByHand: StoandlClient.linkPause.split(",").indexOf("manual") >= 0
    readonly property bool pausedForQuietTime: StoandlClient.linkPause.split(",").indexOf("quiet_time") >= 0

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    // The initial loads (watch list + firmware check) wait for the window's first frame, so the
    // window maps before any D-Bus round trip; see the Connections/Timer below.
    property bool loadsStarted: false

    function startLoads() {
        if (page.loadsStarted)
            return;
        page.loadsStarted = true;
        // 20 s safety-net poll runs only while this tab shows (live updates arrive via the
        // WatchesChanged signal; this is the BluetoothStatus carrier + missed-signal fallback).
        StoandlClient.startWatchPoll();
    }

    // The page is kept while another tab shows (Main.qml): the poll stops when it goes and restarts,
    // with an immediate refresh, when Main brings it back. A page pushed over it keeps it visible.
    onVisibleChanged: if (!page.visible) StoandlClient.stopWatchPoll()
    function refreshOnShow() {
        if (page.loadsStarted)
            StoandlClient.startWatchPoll();
    }

    // The only firmware-check trigger. The key is the name:state of every watch: a watch that connects,
    // reboots after a flash or comes up in recovery gets a fresh CheckFirmware, so the update banner
    // reflects what it runs now; an unchanged key reuses StoandlClient's cached answer.
    function applyWatches(rows) {
        page.watches = rows;
        var found = null;
        var states = [];
        for (var i = 0; i < rows.length; ++i) {
            if (rows[i].connected && !found) found = rows[i];
            states.push(rows[i].name + ":" + rows[i].state);
        }
        page.connectedWatch = found;
        StoandlClient.requestFirmwareCheck(states.join(","));
    }

    // The Battery page starts from this page's watch list (and follows watchesChanged after that).
    function openBattery() { return applicationWindow().pushPage(batteryPageComponent, { watchRows: page.watches }); }

    // The three dialogs are built on first use, not with the page (a Loader each, below).
    function detailsDialogItem() { detailsLoader.active = true; return detailsLoader.item; }
    function pairDialogItem() { pairLoader.active = true; return pairLoader.item; }
    function forgetDialogItem() { forgetLoader.active = true; return forgetLoader.item; }

    function connectTo(name) {
        var r = StoandlClient.connectWatch(name);
        if (!r.ok)
            page.toast("Connect failed: " + (r.tail || r.kind));
        StoandlClient.refreshWatches(); // re-fetch after mutation
    }

    // UpdateFirmware downloads the release first (seconds), so it runs without blocking; the flash
    // progress then arrives through StoandlClient's firmwareStatus.
    function updateFirmware() {
        StoandlClient.run(page, ["updateFirmware"], function (r) {
            if (r.ok) page.toast("Firmware flash started…");
            else if (r.kind === "uptodate") page.toast("Already up to date");
            else page.toast("Firmware: " + (r.tail !== "" ? r.tail : r.kind));
        });
    }

    function resumeLink() {
        var r = StoandlClient.connectWatch("");
        page.toast(r.ok ? (r.tail || "Watch connection resumed") : "Connect failed: " + (r.tail || r.kind));
        StoandlClient.refreshWatches();
    }

    function stateColor(state) {
        if (state === "connected")  return Kirigami.Theme.positiveTextColor;
        if (state === "connecting" || state === "recovery") return Kirigami.Theme.neutralTextColor;
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
        // A downgrade reboots into recovery first and is flashed from there (StoandlClient keeps
        // this phase until the recovery flash starts, across the watch's disconnect).
        if (fwPhase === "prf")         return "Rebooting into recovery to downgrade" + (fwDetail ? " to " + fwDetail : "") + "…";
        return "Working…";
    }

    // The watch list (and the firmware check a changed one starts) follows only while this tab shows;
    // refreshOnShow() catches up.
    Connections {
        target: StoandlClient
        enabled: page.visible
        function onWatchesChanged(rows) { page.applyWatches(rows); }
        function onDaemonUpChanged() {
            if (StoandlClient.daemonUp && page.loadsStarted)
                StoandlClient.refreshWatches();   // → applyWatches → the firmware check
        }
    }
    Connections {
        target: StoandlClient
        function onPairStatus(kind, msg) { if (pairLoader.item) pairLoader.item.handleStatus(kind, msg); }
        function onFindWatchResult(ok) {
            page.toast(ok ? "Ringing watch…" : "No watch ready to ring");
        }
        function onFirmwareStatus(kind, percent, detail) {
            if (kind === "success") { page.toast("Firmware flashed — watch is rebooting"); page.fwPhase = ""; page.fwPercent = -1; } // StoandlClient drops the stale firmwareInfo
            else if (kind === "failed") { page.toast("Flash failed: " + detail); page.fwPhase = ""; page.fwPercent = -1; }
            else if (kind === "timeout") { page.toast("Flash timed out"); page.fwPhase = ""; page.fwPercent = -1; }
            else if (kind === "idle") { page.fwPhase = ""; page.fwPercent = -1; } // terminal: no flash in flight → hide the banner
            else { page.fwPhase = kind; page.fwPercent = percent; page.fwDetail = detail; }
        }
    }

    // Window before data: start the loads once the window has put a frame on screen. A page recreated
    // by a tab switch gets one too (the switch repaints); the timer covers a window that doesn't
    // render (not exposed yet, minimised).
    Connections {
        target: page.Window.window
        enabled: !page.loadsStarted
        function onFrameSwapped() { Qt.callLater(page.startLoads); }
    }
    Timer {
        running: !page.loadsStarted
        interval: 500
        onTriggered: page.startLoads()
    }
    Component.onDestruction: StoandlClient.stopWatchPoll()

    // Headless smoke (STOANDL_SMOKE_MS): the pairing dialog's status line is only reached through a
    // button and a live pairing window, so hand it the daemon's two search states directly. Then push
    // the Battery page, which the card only offers with a watch connected, so a MOCK_NO_WATCH run
    // reaches its "No watch connected" state.
    function smokeExercise() {
        console.log("stoandl-smoke: firmware checking=" + StoandlClient.firmwareChecking
                    + " kind=" + (page.fwInfo.kind || "none") + " update=" + page.updateAvailable);
        var pd = page.pairDialogItem();
        pd.handleStatus("pending", "");
        var bare = pd.statusMsg;
        pd.handleStatus("pending", "Discovery paused — Bluetooth is off. Turn it on to pair.");
        console.log("stoandl-smoke: pair status bare='" + bare + "' note='" + pd.statusMsg + "'");
        pd.statusKind = "";
        pd.statusMsg = "";
        // The details dialog (built on first use) shows the cached firmware answer; the hero card
        // that opens it is only there with a watch connected.
        if (StoandlClient.daemonUp && page.connectedWatch !== null) {
            var dd = page.detailsDialogItem();
            dd.openFor();
            console.log("stoandl-smoke: details dialog firmware='" + dd.fwState + "'");
            dd.close();
            StoandlClient.forceFirmwareCheck();   // Sync now / Check for updates: re-asks past the cache
            console.log("stoandl-smoke: firmware forced checking=" + StoandlClient.firmwareChecking);
            // A watch task: started here, its result reported by Main.qml (smokeWhenIdle waits for it).
            var shot = StoandlClient.takeScreenshot();
            console.log("stoandl-smoke: screenshot start " + shot.kind + ":" + shot.tail
                        + " running=" + ("screenshot" in StoandlClient.tasks));
        }
        var bp = page.openBattery();
        applicationWindow().smokeWhenIdle(function () {
            console.log("stoandl-smoke: battery kind=" + (bp.insights ? bp.insights.kind : "none")
                        + " watchConnected=" + bp.watchConnected + " hasInsights=" + bp.hasInsights);
        });
        // Disconnect → paused banner → Connect (the round trip MOCK_LINK_PAUSE=manual starts halfway).
        var before = "byHand=" + page.pausedByHand + " quietTime=" + page.pausedForQuietTime;
        if (!page.pausedByHand) { StoandlClient.disconnectWatch(); StoandlClient.refreshWatches(); }
        var held = page.pausedByHand;
        page.resumeLink();
        console.log("stoandl-smoke: link pause " + before + " disconnect=" + held + " resumed=" + !page.pausedByHand);
        // STOANDL_SMOKE_FLASH=1: start a flash the way Settings → Diagnostics & developer does (sideloadFirmware, which
        // arms the firmware poll), so the phase handling — the prf walk with MOCK_FW_DOWNGRADE=1 or
        // drop — runs end to end and lands on this page's banner. The path doesn't exist: the mock
        // walks any path, a real daemon refuses it.
        if (StoandlClient.smokeFlash) {
            var r = StoandlClient.sideloadFirmware("file:///nonexistent/stoandl-smoke.pbz");
            console.log("stoandl-smoke: sideload " + r.kind);
        }
    }

    // Page actions: header (desktop) / footer toolbar (mobile). NOT a Material FAB.
    actions: [
        Kirigami.Action {
            icon.name: "list-add"
            text: "Pair new watch"
            enabled: StoandlClient.daemonUp && StoandlClient.bluetoothOn
            onTriggered: page.pairDialogItem().openForPair()
        },
        Kirigami.Action {
            icon.name: "find-location-symbolic"
            text: "Ring watch"
            enabled: StoandlClient.daemonUp && page.connectedWatch !== null
            onTriggered: StoandlClient.findWatch()
        },
        Kirigami.Action {
            icon.name: "network-disconnect-symbolic"
            text: "Disconnect"
            tooltip: "Keep the watch disconnected until you connect it again"
            visible: StoandlClient.daemonUp && page.connectedWatch !== null && !page.pausedByHand
            onTriggered: {
                var r = StoandlClient.disconnectWatch();
                if (!r.ok)
                    page.toast("Disconnect failed: " + (r.tail || r.kind));
                StoandlClient.refreshWatches();
            }
        },
        Kirigami.Action {
            icon.name: "view-refresh-symbolic"
            text: "Sync now"
            enabled: StoandlClient.daemonUp
            onTriggered: { StoandlClient.refreshWatches(); StoandlClient.forceFirmwareCheck(); page.toast("Refreshed"); }
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
        // The daemon detects this (BlueZ: no powered adapter) and reconnects on its
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

        // --- notification.forward off (its control is in Settings → Notifications) ---
        ForwardingBanner {
            Layout.fillWidth: true
        }

        // --- link paused: by hand (Disconnect), or for Quiet Time --------------
        Kirigami.InlineMessage {
            visible: StoandlClient.daemonUp && page.pausedByHand
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.largeSpacing
            Layout.leftMargin: Kirigami.Units.largeSpacing
            Layout.rightMargin: Kirigami.Units.largeSpacing
            type: Kirigami.MessageType.Information
            icon.source: "network-disconnect-symbolic"
            text: "Watch disconnected — no watch connects until you connect it again."
            actions: [
                Kirigami.Action {
                    icon.name: "network-connect-symbolic"
                    text: "Connect"
                    onTriggered: page.resumeLink()
                }
            ]
        }
        Kirigami.InlineMessage {
            visible: StoandlClient.daemonUp && page.pausedForQuietTime && !page.pausedByHand
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.largeSpacing
            Layout.leftMargin: Kirigami.Units.largeSpacing
            Layout.rightMargin: Kirigami.Units.largeSpacing
            type: Kirigami.MessageType.Information
            icon.source: "weather-clear-night-symbolic"
            text: "Watch connection paused for Quiet Time. It comes back when Quiet Time ends or the display comes on."
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
                onTriggered: page.pairDialogItem().openForPair()
            }
        }

        // --- firmware: flashing-in-progress --------------------------------
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp && page.fwBusy
            title: "Updating firmware"
        }
        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.fwBusy

            // A bare QQC2.ProgressBar as a direct FormCard child lays out with no usable height (you'd
            // only see the phase text). Wrap the label + bar in an AbstractFormDelegate's ColumnLayout —
            // the same pattern the notifications dialog uses for custom FormCard content — and give the
            // bar an explicit height so it's clearly visible.
            FormCard.AbstractFormDelegate {
                Layout.fillWidth: true
                background: null
                hoverEnabled: false
                contentItem: ColumnLayout {
                    spacing: Kirigami.Units.smallSpacing
                    QQC2.Label {
                        Layout.fillWidth: true
                        text: page.fwPhaseLabel()
                        wrapMode: Text.WordWrap   // the recovery-downgrade line is long on a phone
                    }
                    QQC2.ProgressBar {
                        Layout.fillWidth: true
                        Layout.topMargin: Kirigami.Units.smallSpacing
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 0.75
                        from: 0
                        to: 100
                        value: page.fwPercent < 0 ? 0 : page.fwPercent
                        indeterminate: page.fwPercent < 0
                    }
                }
            }
        }

        // --- firmware: check in flight (only once it has taken a moment) ----
        Kirigami.InlineMessage {
            visible: StoandlClient.daemonUp && !page.fwBusy && page.connectedWatch !== null
                     && StoandlClient.firmwareChecking && fwCheckDelay.elapsed
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.largeSpacing
            Layout.leftMargin: Kirigami.Units.largeSpacing
            Layout.rightMargin: Kirigami.Units.largeSpacing
            type: Kirigami.MessageType.Information
            icon.source: "view-refresh-symbolic"
            text: "Checking for firmware updates…"
        }
        // A check the daemon answers at once (firmware sources off, no watch) shows no banner.
        Timer {
            id: fwCheckDelay
            property bool elapsed: false
            interval: 400
            running: StoandlClient.firmwareChecking
            onRunningChanged: if (running) elapsed = false
            onTriggered: elapsed = true
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
            text: page.updateAvailable ? ("PebbleOS " + page.fwInfo.latest + " available") : ""
            actions: [
                Kirigami.Action {
                    icon.name: "install-symbolic"
                    text: "Update now"
                    onTriggered: page.updateFirmware()
                },
                Kirigami.Action {
                    icon.name: "globe-symbolic"
                    text: "What’s new"
                    enabled: (page.fwInfo.changelogUrl || "") !== ""
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
                onClicked: page.detailsDialogItem().openFor()

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

        // --- battery insights (opens the rich chart page) ------------------
        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.connectedWatch !== null

            FormCard.FormButtonDelegate {
                icon.name: "battery-symbolic"
                text: "Battery insights"
                description: "Charge trend, voltage, time remaining"
                onClicked: page.openBattery()
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

                    // Tap connects (unless already active, or connected in recovery).
                    onClicked: {
                        if (modelData.state === "disconnected")
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
                                // A watch in recovery (PRF) is connected, but only for a firmware flash
                                // (Settings → Diagnostics & developer), a core dump and its logs.
                                text: watchRow.modelData.state === "connected"
                                      ? (page.transportLabel(watchRow.modelData.transport)
                                         + (watchRow.modelData.battery !== "" ? " · " + watchRow.modelData.battery + "%" : ""))
                                      : watchRow.modelData.state === "recovery"
                                        ? "In recovery (PRF) — flash a firmware to bring it back"
                                        : (watchRow.modelData.state === "connecting" ? "Connecting…" : "disconnected")
                                elide: Text.ElideRight
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                            }
                        }

                        StatusChip {
                            visible: watchRow.modelData.state !== "disconnected"
                            label: watchRow.modelData.state === "connected" ? "active" : watchRow.modelData.state
                            tint: page.stateColor(watchRow.modelData.state)
                        }

                        QQC2.Button {
                            visible: watchRow.modelData.state === "disconnected"
                            text: "Connect"
                            onClicked: page.connectTo(watchRow.modelData.name)
                        }

                        QQC2.ToolButton {
                            icon.name: "edit-delete-remove-symbolic"
                            display: QQC2.AbstractButton.IconOnly
                            QQC2.ToolTip.text: "Forget watch"
                            QQC2.ToolTip.visible: hovered
                            onClicked: page.forgetDialogItem().openFor(watchRow.modelData.name)
                        }
                    }
                }
            }
        }
    }

    // --- Watch details dialog (§4d) ----------------------------------------
    Loader {
        id: detailsLoader
        active: false
        sourceComponent: WatchDetailsDialog {
            onForgetRequested: function(name) { page.forgetDialogItem().openFor(name); }
        }
    }

    // Battery insights sub-page (pushed from the "Battery insights" row above).
    Component { id: batteryPageComponent; BatteryPage {} }

    // --- pairing dialog (Pair + Repair) ------------------------------------
    Loader {
        id: pairLoader
        active: false
        sourceComponent: Kirigami.PromptDialog {
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
                // Every other message is the daemon's own words (a found watch, or why the window can't
                // discover right now), shown as it changes. A bare `pending:` is "open, nothing found yet".
                statusMsg = msg !== "" ? msg
                          : kind === "pending" ? "Searching for a watch in pairing mode…"
                          : kind;
                if (kind === "ok") {
                    // "Paired and connected", "Paired", or "Watch already connected" (no window opened).
                    page.toast(msg !== "" ? msg : "Watch paired");
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
    }

    // --- forget (unpair) confirmation --------------------------------------
    Loader {
        id: forgetLoader
        active: false
        sourceComponent: Kirigami.PromptDialog {
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
}
