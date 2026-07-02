import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import QtQuick.Dialogs as Dialogs
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// Watch details (opened by tapping the connected-watch hero card). Holds the
// hardware facts that used to live in the inline HARDWARE list, plus the
// developer connection, language picker, rename, and the Debug submenu of
// low-level diagnostic / recovery tools (handoff §4d). Bottom sheet on mobile /
// popup on desktop — Kirigami.Dialog adapts.
Kirigami.Dialog {
    id: dialog

    signal forgetRequested(string name)

    // 'main' | 'debug' | 'language'
    property string view: "main"
    property var details: ({})
    property bool devOn: false
    property var languages: []
    property string currentLang: "English (US)"

    title: view === "debug" ? "Debug"
         : view === "language" ? "Watch language"
         : (details.name ? (details.name + (details.code ? " · " + details.code : "")) : "Watch")

    preferredWidth: Kirigami.Units.gridUnit * 25
    standardButtons: QQC2.Dialog.Close
    showCloseButton: true

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    function openFor() {
        view = "main";
        var d = StoandlClient.watchDetails();
        details = (d.kind === "ok") ? d : ({});
        devOn = StoandlClient.devConnectionStatus().active === true;
        loadLanguages();
        open();
    }

    function loadLanguages() {
        var rows = StoandlClient.daemonUp ? StoandlClient.listLanguages() : [];
        languages = rows;
        // Reset first so a snapshot with no installed pack doesn't show a stale one.
        currentLang = "—";
        for (var i = 0; i < rows.length; ++i) {
            if (rows[i].installed) { currentLang = rows[i].displayName; break; }
        }
    }

    Connections {
        target: StoandlClient
        function onLanguageStatus(kind, percent, detail) {
            if (kind === "success") { dialog.toast("Language pack installed"); dialog.loadLanguages(); }
            else if (kind === "failed") dialog.toast("Language install failed: " + detail);
            else if (kind === "disconnected") dialog.toast("Watch disconnected during install");
        }
        function onCliResult(op, ok, message) {
            if (op === "support")
                dialog.toast(ok ? "Support bundle created" : ("Support bundle failed: " + message));
        }
    }

    // A label/value fact row.
    component DetailRow: RowLayout {
        property string label
        property string value
        property bool mono: false
        Layout.fillWidth: true
        spacing: Kirigami.Units.largeSpacing
        QQC2.Label { text: parent.label; opacity: 0.7 }
        Item { Layout.fillWidth: true }
        QQC2.Label {
            text: parent.value
            horizontalAlignment: Text.AlignRight
            font.family: parent.mono ? "monospace" : Kirigami.Theme.defaultFont.family
            font.bold: true
            elide: Text.ElideRight
        }
    }

    // An action row in the main/debug lists.
    component ActionRow: QQC2.ItemDelegate {
        property string iconName
        property bool danger: false
        property bool chevron: false
        property bool soon: false
        Layout.fillWidth: true
        contentItem: RowLayout {
            spacing: Kirigami.Units.largeSpacing
            Kirigami.Icon {
                source: parent.parent.iconName
                color: parent.parent.danger ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
                implicitWidth: Kirigami.Units.iconSizes.smallMedium
                implicitHeight: Kirigami.Units.iconSizes.smallMedium
            }
            QQC2.Label {
                Layout.fillWidth: true
                text: parent.parent.text
                color: parent.parent.danger ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
            }
            StatusChip {
                visible: parent.parent.soon
                label: "SOON"
                tint: Kirigami.Theme.disabledTextColor
            }
            Kirigami.Icon {
                visible: parent.parent.chevron
                source: "go-next-symbolic"
                implicitWidth: Kirigami.Units.iconSizes.small
                implicitHeight: Kirigami.Units.iconSizes.small
                opacity: 0.6
            }
        }
    }

    ColumnLayout {
        spacing: 0
        // Keep the dialog from collapsing when an empty view is hidden.
        Layout.preferredWidth: Kirigami.Units.gridUnit * 25

        // ============ MAIN VIEW ============
        ColumnLayout {
            visible: dialog.view === "main"
            Layout.fillWidth: true
            spacing: 0

            // Detail facts.
            ColumnLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.smallSpacing

                DetailRow { label: "Model";     value: dialog.details.model || "—" }
                DetailRow { label: "Platform";  value: dialog.details.platform || "—" }
                DetailRow { label: "Transport"; value: dialog.details.transport || "—" }

                // Firmware row + permanent "What's new" link.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing
                    QQC2.Label { text: "Firmware"; opacity: 0.7 }
                    Item { Layout.fillWidth: true }
                    QQC2.Label { text: dialog.details.firmware || "—"; font.bold: true }
                    QQC2.ToolButton {
                        text: "What’s new"
                        icon.name: "globe-symbolic"
                        display: QQC2.AbstractButton.TextBesideIcon
                        flat: true
                        onClicked: {
                            var fw = StoandlClient.checkFirmware();
                            if (fw.kind === "ok" && fw.changelogUrl)
                                Qt.openUrlExternally(fw.changelogUrl);
                            else
                                dialog.toast("No changelog available");
                        }
                    }
                }

                DetailRow { label: "Serial";    value: dialog.details.serial || "—"; mono: true }
                DetailRow { label: "Battery";   value: dialog.details.battery ? dialog.details.battery + "%" : "—" }
                DetailRow { label: "Last sync"; value: dialog.details.lastSync || "—" }

                Kirigami.Separator { Layout.fillWidth: true; Layout.topMargin: Kirigami.Units.smallSpacing }

                // Developer connection — toggle.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing
                    ColumnLayout {
                        spacing: 0
                        QQC2.Label { text: "Developer connection" }
                        QQC2.Label {
                            text: "SDK / CloudPebble bridge on port 9000"
                            font: Kirigami.Theme.smallFont
                            opacity: 0.7
                        }
                    }
                    Item { Layout.fillWidth: true }
                    QQC2.Switch {
                        checked: dialog.devOn
                        onToggled: {
                            var r = checked ? StoandlClient.startDevConnection()
                                            : StoandlClient.stopDevConnection();
                            if (r.kind === "ok") {
                                dialog.devOn = checked;
                                dialog.toast(checked ? ("Developer connection · listening on " + (r.port || "9000"))
                                                     : "Developer connection stopped");
                            } else {
                                checked = dialog.devOn;   // revert
                                dialog.toast("Developer connection: " + (r.tail || r.kind));
                            }
                        }
                    }
                }
            }

            Kirigami.Separator { Layout.fillWidth: true }

            // Language row -> picker.
            QQC2.ItemDelegate {
                Layout.fillWidth: true
                onClicked: dialog.view = "language"
                contentItem: RowLayout {
                    spacing: Kirigami.Units.largeSpacing
                    Kirigami.Icon { source: "globe-symbolic"; implicitWidth: Kirigami.Units.iconSizes.smallMedium; implicitHeight: Kirigami.Units.iconSizes.smallMedium }
                    QQC2.Label { text: "Language"; Layout.fillWidth: true }
                    QQC2.Label { text: dialog.currentLang; opacity: 0.7 }
                    Kirigami.Icon { source: "go-next-symbolic"; implicitWidth: Kirigami.Units.iconSizes.small; implicitHeight: Kirigami.Units.iconSizes.small; opacity: 0.6 }
                }
            }

            Kirigami.Separator { Layout.fillWidth: true }

            // Main actions.
            ActionRow {
                text: "Rename watch…"; iconName: "document-edit-symbolic"
                onClicked: renameDialog.openFor()
            }
            ActionRow {
                text: "Capture screenshot"; iconName: "camera-photo-symbolic"
                onClicked: {
                    var r = StoandlClient.takeScreenshot();
                    dialog.toast(r.kind === "ok" ? ("Screenshot saved: " + r.path)
                                                 : ("Screenshot: " + (r.msg || r.kind)));
                }
            }
            ActionRow {
                text: "Check for updates"; iconName: "view-refresh-symbolic"
                onClicked: {
                    var fw = StoandlClient.checkFirmware();
                    if (fw.kind === "ok")
                        dialog.toast(fw.updateAvailable ? ("PebbleOS " + fw.latest + " available")
                                                        : "Firmware up to date");
                    else
                        dialog.toast("Firmware: " + (fw.tail || fw.kind));
                }
            }
            ActionRow {
                text: "Debug…"; iconName: "tools-symbolic"; chevron: true
                onClicked: dialog.view = "debug"
            }
            ActionRow {
                text: "Forget watch"; iconName: "edit-delete-remove-symbolic"; danger: true
                onClicked: {
                    var name = dialog.details.name || "";
                    dialog.close();
                    dialog.forgetRequested(name);
                }
            }
        }

        // ============ DEBUG VIEW ============
        ColumnLayout {
            visible: dialog.view === "debug"
            Layout.fillWidth: true
            spacing: 0

            ActionRow {
                text: "Back"; iconName: "go-previous-symbolic"
                onClicked: dialog.view = "main"
            }
            Kirigami.Separator { Layout.fillWidth: true }

            QQC2.Label {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.largeSpacing
                text: "Low-level tools for diagnostics and recovery. Use with care."
                font: Kirigami.Theme.smallFont
                opacity: 0.7
                wrapMode: Text.WordWrap
            }

            ActionRow {
                text: "Core dump"; iconName: "documentinfo-symbolic"
                onClicked: {
                    var r = StoandlClient.getCoreDump();
                    dialog.toast(r.kind === "ok" ? ("Core dump saved: " + r.path)
                               : r.kind === "none" ? "No core dump available"
                               : ("Core dump: " + (r.msg || r.kind)));
                }
            }
            ActionRow {
                text: "Pull watch logs"; iconName: "text-x-generic-symbolic"
                onClicked: {
                    var r = StoandlClient.gatherLogs();
                    dialog.toast(r.kind === "ok" ? ("Logs saved: " + r.path) : ("Logs: " + (r.msg || r.kind)));
                }
            }
            ActionRow {
                text: "Support bundle"; iconName: "help-feedback-symbolic"
                onClicked: { StoandlClient.supportBundle(""); dialog.toast("Building support bundle…"); }
            }
            ActionRow {
                text: "Reboot to recovery (PRF)"; iconName: "system-reboot-symbolic"
                onClicked: recoveryConfirm.open()
            }
            ActionRow {
                text: "Flash firmware from file…"; iconName: "system-software-update-symbolic"
                onClicked: fwFileDialog.open()
            }
            ActionRow {
                text: "Write notification"; iconName: "notifications-symbolic"; soon: true
                enabled: false
            }
            ActionRow {
                text: "Factory reset"; iconName: "dialog-warning-symbolic"; danger: true
                onClicked: factoryConfirm.open()
            }
        }

        // ============ LANGUAGE VIEW ============
        ColumnLayout {
            visible: dialog.view === "language"
            Layout.fillWidth: true
            spacing: 0

            ActionRow {
                text: "Back"; iconName: "go-previous-symbolic"
                onClicked: dialog.view = "main"
            }
            Kirigami.Separator { Layout.fillWidth: true }

            QQC2.Label {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.largeSpacing
                text: "Load a language pack onto the watch. The current one is marked."
                font: Kirigami.Theme.smallFont
                opacity: 0.7
                wrapMode: Text.WordWrap
            }

            Repeater {
                model: dialog.languages
                delegate: QQC2.ItemDelegate {
                    id: langRow
                    required property var modelData
                    Layout.fillWidth: true
                    onClicked: {
                        if (modelData.installed) {
                            dialog.toast(modelData.displayName + " already loaded");
                            return;
                        }
                        var r = StoandlClient.installLanguage(modelData.id);
                        dialog.toast(r.ok ? ("Loading " + modelData.displayName + " onto watch…")
                                          : ("Language: " + (r.tail || r.kind)));
                    }
                    contentItem: RowLayout {
                        spacing: Kirigami.Units.largeSpacing
                        Kirigami.Icon {
                            source: "globe-symbolic"
                            color: langRow.modelData.installed ? Kirigami.Theme.highlightColor : Kirigami.Theme.textColor
                            implicitWidth: Kirigami.Units.iconSizes.smallMedium
                            implicitHeight: Kirigami.Units.iconSizes.smallMedium
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            QQC2.Label { text: langRow.modelData.displayName }
                            QQC2.Label { text: langRow.modelData.id + " · " + langRow.modelData.source; font: Kirigami.Theme.smallFont; opacity: 0.7 }
                        }
                        Kirigami.Icon {
                            visible: langRow.modelData.installed
                            source: "checkmark-symbolic"
                            color: Kirigami.Theme.highlightColor
                            implicitWidth: Kirigami.Units.iconSizes.small
                            implicitHeight: Kirigami.Units.iconSizes.small
                        }
                    }
                }
            }
        }
    }

    // --- rename ------------------------------------------------------------
    Kirigami.PromptDialog {
        id: renameDialog
        title: "Rename watch"
        standardButtons: QQC2.Dialog.NoButton

        function openFor() { nameField.text = dialog.details.name || ""; open(); }

        ColumnLayout {
            spacing: Kirigami.Units.largeSpacing
            QQC2.Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: "Choose a display name for this watch." }
            QQC2.TextField { id: nameField; Layout.fillWidth: true; placeholderText: "Watch name" }
        }
        customFooterActions: [
            Kirigami.Action {
                text: "Rename"
                icon.name: "document-edit-symbolic"
                enabled: nameField.text.trim() !== ""
                onTriggered: {
                    var r = StoandlClient.setWatchNickname(dialog.details.name || "", nameField.text.trim());
                    if (r.ok) {
                        dialog.toast("Renamed to " + nameField.text.trim());
                        StoandlClient.refreshWatches();
                        dialog.close();
                    } else {
                        dialog.toast("Rename failed: " + (r.tail || r.kind));
                    }
                    renameDialog.close();
                }
            },
            Kirigami.Action { text: "Cancel"; icon.name: "dialog-cancel-symbolic"; onTriggered: renameDialog.close() }
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
            dialog.toast(r.ok ? "Recovery reboot queued" : ("Failed: " + (r.tail || r.kind)));
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
                    dialog.toast(r.ok ? "Factory reset queued" : ("Failed: " + (r.tail || r.kind)));
                    factoryConfirm.close();
                }
            },
            Kirigami.Action { text: "Cancel"; icon.name: "dialog-cancel-symbolic"; onTriggered: factoryConfirm.close() }
        ]
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
            if (r.ok) {
                dialog.toast("Flashing firmware…");
                dialog.close();   // reveal the Watch page's flash-progress banner
            } else {
                dialog.toast("Flash failed: " + (r.tail || r.kind));
            }
        }
    }
}
