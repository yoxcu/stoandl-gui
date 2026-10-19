import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import QtQuick.Dialogs as Dialogs
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// Diagnostics & developer — the developer corner of Settings: the Developer page's stoandl.conf keys
// (SchemaSections) on top, then the support bundle and the low-level diagnostic, recovery and testing
// tools (they used to hang off the watch-details dialog, which hid them behind the connected-watch
// card). Grouped Diagnostics / Recovery / Testing, with the one destructive action in a danger position
// last.
//
// The support bundle is CLI-local (`stoandl support`), like backup and restore: it shells out to the
// co-located binary and reports back via cliResult. It needs no watch.
//
// Every tool acts on "the connected watch", so the rows are disabled (with an inline explanation) until
// a watch is connected. Most daemon methods here take no watch argument at all; the heartbeat ones do,
// but the daemon resolves it among CONNECTED watches only, so with none connected they answer
// `unknown:` even when records are stored. A watch in its recovery firmware (ListWatches `recovery`)
// is reachable for the core dump, the logs and a firmware flash (that is how it gets back), not for
// the rest.
Kirigami.ScrollablePage {
    id: page
    objectName: "debugSettings"
    title: "Diagnostics & developer"

    // Latest ListWatches verdict: is any watch connected right now, or connected in recovery (PRF)?
    property bool watchConnected: false
    property bool watchInRecovery: false
    // Guard for the rows that need the watch's normal firmware.
    readonly property bool watchTools: StoandlClient.daemonUp && page.watchConnected
    // Guard for the rows the daemon also serves on a watch in recovery.
    readonly property bool recoveryTools: StoandlClient.daemonUp && (page.watchConnected || page.watchInRecovery)

    Component { id: heartbeatPage; HeartbeatPage {} }

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }
    function open(component) { return applicationWindow().pushPage(component); }

    // Headless smoke (STOANDL_SMOKE_MS): the Developer keys, and the heartbeat page, only reachable from here.
    function smokeExercise() {
        developerSections.smokeExercise();
        console.log("stoandl-smoke: debug watchTools=" + page.watchTools + " recoveryTools=" + page.recoveryTools);
        if (page.watchTools)
            StoandlClient.run(page, ["ping"], function (r) { console.log("stoandl-smoke: ping " + r.kind + " " + r.tail); });
        if (page.recoveryTools) {
            // Two watch tasks at once (one per kind); Main.qml reports each when it ends.
            console.log("stoandl-smoke: logs start " + StoandlClient.gatherLogs().kind
                        + ", core dump start " + StoandlClient.getCoreDump().kind);
        }
        var hb = page.open(heartbeatPage);
        applicationWindow().smokeWhenIdle(function () { hb.smokeExercise(); });   // once its reads are in
        // Back, as someone would, before the walk goes on.
        applicationWindow().smokeWhenIdle(function () { applicationWindow().pageStack.pop(); });
    }

    function applyWatches(rows) {
        var found = false, recovery = false;
        for (var i = 0; i < rows.length; ++i) {
            if (rows[i].connected) found = true;
            if (rows[i].recovery) recovery = true;
        }
        page.watchConnected = found;
        page.watchInRecovery = recovery;
    }

    function reload() {
        if (StoandlClient.daemonUp)
            StoandlClient.fetch(page, ["listWatches"], page.applyWatches);
        else
            page.applyWatches([]);
    }

    Connections {
        target: StoandlClient
        // Live connect/disconnect arrives via WatchesChanged (the client subscribes to it always);
        // the daemonUp re-sync is the missed-signal net.
        function onWatchesChanged(rows) { page.applyWatches(rows); }
        function onDaemonUpChanged() { page.reload(); }
        function onCliResult(op, ok, message) {
            if (op === "support")
                page.toast(ok ? "Support bundle created" : ("Support bundle failed: " + message));
        }
    }

    Component.onCompleted: page.reload()

    ColumnLayout {
        spacing: 0

        DaemonPlaceholder {
            visible: !StoandlClient.daemonUp
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
        }

        // The Developer page's stoandl.conf keys (developer connection, app data logs).
        SchemaSections {
            id: developerSections
            visible: StoandlClient.daemonUp
            Layout.fillWidth: true
            pageName: "Developer"
            flickable: page.flickable
        }

        FormCard.FormSectionText {
            visible: StoandlClient.daemonUp
            text: "Low-level tools for diagnostics and recovery. Use with care."
        }

        // No watch (or one in recovery) → some rows below are disabled; say why instead of leaving them dead.
        Kirigami.InlineMessage {
            visible: StoandlClient.daemonUp && !page.watchConnected
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.largeSpacing
            Layout.rightMargin: Kirigami.Units.largeSpacing
            Layout.topMargin: Kirigami.Units.largeSpacing
            type: page.watchInRecovery ? Kirigami.MessageType.Warning : Kirigami.MessageType.Information
            text: page.watchInRecovery
                  ? "The watch is in recovery (PRF). Flash a firmware to bring it back; the core dump and "
                    + "watch logs work too, the other tools need its normal firmware."
                  : "No watch is connected. These tools act on the connected watch, so they stay disabled "
                    + "until one is."
        }

        FormCard.FormHeader {
            visible: StoandlClient.daemonUp
            title: "Diagnostics"
        }
        FormCard.FormCard {
            visible: StoandlClient.daemonUp

            FormCard.FormButtonDelegate {
                text: "Create support bundle…"
                description: "stoandl's logs and state for a bug report, with secrets left out"
                icon.name: "help-feedback-symbolic"
                onClicked: supportDialog.openWithName()
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormButtonDelegate {
                text: "Pull watch logs"
                description: "Fetch the watch's on-device log to a file"
                icon.name: "text-x-generic-symbolic"
                enabled: page.recoveryTools && !("logs" in StoandlClient.tasks)
                // Watch tasks: Main.qml reports the file with an Open folder action.
                onClicked: {
                    var r = StoandlClient.gatherLogs();
                    page.toast(r.ok ? "Reading the watch's logs…" : ("Watch logs: " + (r.tail || r.kind)));
                }
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormButtonDelegate {
                text: "Core dump"
                description: "Save the watch's last crash dump to a file"
                icon.name: "documentinfo-symbolic"
                enabled: page.recoveryTools && !("coredump" in StoandlClient.tasks)
                onClicked: {
                    var r = StoandlClient.getCoreDump();
                    page.toast(r.ok ? "Reading the watch's core dump…" : ("Core dump: " + (r.tail || r.kind)));
                }
            }
            FormCard.FormDelegateSeparator {}
            // The newest record the daemon stored for the connected watch.
            FormCard.FormButtonDelegate {
                text: "Analytics heartbeat"
                description: "The watch's hourly diagnostic record, metric by metric"
                icon.name: "office-chart-line-symbolic"
                enabled: page.watchTools
                onClicked: page.open(heartbeatPage)
            }
        }

        FormCard.FormHeader {
            visible: StoandlClient.daemonUp
            title: "Recovery"
        }
        FormCard.FormCard {
            visible: StoandlClient.daemonUp

            FormCard.FormButtonDelegate {
                text: "Reboot to recovery (PRF)"
                description: "Restart the watch into its recovery firmware"
                icon.name: "system-reboot-symbolic"
                enabled: page.watchTools
                onClicked: recoveryConfirm.open()
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormButtonDelegate {
                text: "Flash firmware from file…"
                description: "Install a local .pbz firmware bundle"
                icon.name: "system-software-update-symbolic"
                enabled: page.recoveryTools
                onClicked: fwFileDialog.open()
            }
        }

        FormCard.FormHeader {
            visible: StoandlClient.daemonUp
            title: "Testing"
        }
        FormCard.FormCard {
            visible: StoandlClient.daemonUp

            FormCard.FormButtonDelegate {
                text: "Ping the watch"
                description: "A round trip through the whole protocol, not just the Bluetooth link"
                icon.name: "network-connect-symbolic"
                enabled: page.watchTools
                onClicked: StoandlClient.run(page, ["ping"], function (r) {
                    page.toast(r.ok ? (r.tail || "The watch answered") : "Ping: " + (r.tail || r.kind));
                })
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormButtonDelegate {
                text: "Write notification…"
                description: "Send a test notification through the normal mute / style / filter path"
                icon.name: "notifications-symbolic"
                enabled: page.watchTools
                onClicked: testNotifDialog.openFor()
            }
        }

        FormCard.FormHeader {
            visible: StoandlClient.daemonUp
            title: "Danger zone"
        }
        FormCard.FormCard {
            visible: StoandlClient.daemonUp

            // Factory reset is the one destructive action here, so it keeps the negative-colour
            // treatment it had in the watch-details list. FormButtonDelegate hardcodes its label
            // colour, hence the custom content item.
            FormCard.AbstractFormDelegate {
                id: factoryRow
                Layout.fillWidth: true
                enabled: page.watchTools
                // Carries the accessible name; the visible label below renders it.
                text: "Factory reset"
                onClicked: factoryConfirm.open()

                contentItem: RowLayout {
                    spacing: Kirigami.Units.largeSpacing

                    Kirigami.Icon {
                        source: "dialog-warning-symbolic"
                        color: factoryRow.enabled ? Kirigami.Theme.negativeTextColor
                                                  : Kirigami.Theme.disabledTextColor
                        implicitWidth: Kirigami.Units.iconSizes.smallMedium
                        implicitHeight: Kirigami.Units.iconSizes.smallMedium
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        QQC2.Label {
                            Layout.fillWidth: true
                            text: factoryRow.text
                            color: factoryRow.enabled ? Kirigami.Theme.negativeTextColor
                                                      : Kirigami.Theme.disabledTextColor
                            elide: Text.ElideRight
                            Accessible.ignored: true   // the delegate already carries this text
                        }
                        QQC2.Label {
                            Layout.fillWidth: true
                            text: "Wipe the watch back to its out-of-box state"
                            color: Kirigami.Theme.disabledTextColor
                            font: Kirigami.Theme.smallFont
                            elide: Text.ElideRight
                        }
                    }
                }
            }
        }
    }

    // --- write a test notification -----------------------------------------
    Kirigami.PromptDialog {
        id: testNotifDialog
        title: "Write notification"
        standardButtons: QQC2.Dialog.NoButton

        // Qualified open(): the page itself has an open(component) helper for pushing sub-pages.
        function openFor() { testNotifTitle.text = ""; testNotifBody.text = ""; testNotifDialog.open(); }

        ColumnLayout {
            spacing: Kirigami.Units.largeSpacing
            QQC2.Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: "Send a test notification to the watch (through the normal mute / style / filter path)."
            }
            QQC2.TextField { id: testNotifTitle; Layout.fillWidth: true; placeholderText: "Title" }
            QQC2.TextField { id: testNotifBody; Layout.fillWidth: true; placeholderText: "Body (optional)" }
        }
        customFooterActions: [
            Kirigami.Action {
                text: "Send"
                icon.name: "document-send-symbolic"
                enabled: testNotifTitle.text.trim() !== ""
                onTriggered: {
                    var r = StoandlClient.call("SendTestNotification", [testNotifTitle.text.trim(), testNotifBody.text]);
                    page.toast(r.ok ? "Test notification sent" : ("Failed: " + (r.tail || r.kind)));
                    testNotifDialog.close();
                }
            },
            Kirigami.Action { text: "Cancel"; icon.name: "dialog-cancel-symbolic"; onTriggered: testNotifDialog.close() }
        ]
    }

    // --- reboot to recovery confirm ----------------------------------------
    Kirigami.PromptDialog {
        id: recoveryConfirm
        title: "Reboot to recovery"
        subtitle: "Reboot the watch into recovery (PRF) firmware?"
        standardButtons: QQC2.Dialog.Ok | QQC2.Dialog.Cancel
        onAccepted: {
            var r = StoandlClient.resetIntoRecovery();
            page.toast(r.ok ? "Recovery reboot queued" : ("Failed: " + (r.tail || r.kind)));
        }
    }

    // --- factory reset confirm (type-to-confirm) ---------------------------
    Kirigami.PromptDialog {
        id: factoryConfirm
        title: "Factory reset"
        standardButtons: QQC2.Dialog.NoButton
        onClosed: confirmField.text = ""

        ColumnLayout {
            spacing: Kirigami.Units.largeSpacing
            QQC2.Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: "This wipes the watch to its out-of-box state and reboots it. This cannot be undone."
            }
            QQC2.Label { text: "Type yes to confirm:" }
            QQC2.TextField { id: confirmField; Layout.fillWidth: true; placeholderText: "yes" }
        }
        customFooterActions: [
            Kirigami.Action {
                text: "Factory reset"
                icon.name: "dialog-warning-symbolic"
                enabled: confirmField.text.trim().toLowerCase() === "yes"
                onTriggered: {
                    var r = StoandlClient.factoryReset();
                    page.toast(r.ok ? "Factory reset queued" : ("Failed: " + (r.tail || r.kind)));
                    factoryConfirm.close();
                }
            },
            Kirigami.Action { text: "Cancel"; icon.name: "dialog-cancel-symbolic"; onTriggered: factoryConfirm.close() }
        ]
    }

    // --- support bundle -----------------------------------------------------
    // The user chooses where the archive lands (so they know where it is); the chosen absolute path goes
    // to the co-located CLI. A cancelled dialog sends nothing.
    SaveFileDialog {
        id: supportDialog
        fileName: "stoandl-support.tar.gz"
        title: "Save support bundle as"
        nameFilters: ["Support bundles (*.tar.gz *.tgz)", "All files (*)"]
        onAccepted: {
            StoandlClient.supportBundle(selectedFile);
            page.toast("Building support bundle…");
        }
    }

    // --- flash firmware from a local .pbz ----------------------------------
    Dialogs.FileDialog {
        id: fwFileDialog
        title: "Flash firmware (.pbz)"
        nameFilters: ["Pebble firmware (*.pbz)", "All files (*)"]
        onAccepted: {
            fwFlashConfirm.fileUrl = selectedFile;
            fwFlashConfirm.fileName = decodeURIComponent(("" + selectedFile).split("/").pop());
            fwFlashConfirm.open();
        }
    }

    // Confirm before flashing — firmware flashing is the single riskiest op. libpebble3 refuses a
    // bundle that doesn't match the watch's board before sending anything, and the watch keeps a
    // recovery (PRF) firmware, so a bad flash drops to recovery rather than bricking.
    Kirigami.PromptDialog {
        id: fwFlashConfirm
        property url fileUrl
        property string fileName
        title: "Flash firmware"
        subtitle: "Flash “" + fileName + "” onto the watch? Keep it on charge and in range; don’t power it off during the flash."
        standardButtons: QQC2.Dialog.Ok | QQC2.Dialog.Cancel
        onAccepted: {
            var r = StoandlClient.sideloadFirmware(fwFlashConfirm.fileUrl);
            // The live flash-progress banner lives on the Watch tab (it owns the FirmwareStatus poll);
            // here we only confirm the hand-off.
            page.toast(r.ok ? "Flashing firmware…" : ("Flash failed: " + (r.tail || r.kind)));
        }
    }
}
