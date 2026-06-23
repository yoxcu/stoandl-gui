import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs as Dialogs
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// Backup, restore and the support bundle. These are CLI-local (`stoandl backup|restore|support` over
// ~/.config/stoandl) — NOT D-Bus methods — so they shell out to the co-located binary and report back
// via cliResult.
Kirigami.ScrollablePage {
    id: page
    objectName: "backupSettings"
    title: "Backup & diagnostics"

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    Connections {
        target: StoandlClient
        function onCliResult(op, ok, message) {
            if (op === "backup")
                page.toast(ok ? "Backup complete" : ("Backup failed: " + message));
            else if (op === "restore")
                page.toast(ok ? "Restore complete" : ("Restore failed: " + message));
            else if (op === "support")
                page.toast(ok ? "Support bundle created" : ("Support bundle failed: " + message));
        }
    }

    ColumnLayout {
        spacing: 0

        DaemonPlaceholder {
            visible: !StoandlClient.daemonUp
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
        }

        FormCard.FormHeader {
            visible: StoandlClient.daemonUp
            title: "Backup"
        }
        FormCard.FormCard {
            visible: StoandlClient.daemonUp
            FormCard.FormButtonDelegate {
                text: "Back up now"
                description: "Save a full backup of the watch and daemon state"
                icon.name: "document-save-symbolic"
                onClicked: { StoandlClient.backup(""); page.toast("Backing up…"); }
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormButtonDelegate {
                text: "Restore from file…"
                description: "Restore a previously saved backup"
                icon.name: "document-open-symbolic"
                onClicked: restoreDialog.open()
            }
        }

        FormCard.FormHeader {
            visible: StoandlClient.daemonUp
            title: "Diagnostics"
        }
        FormCard.FormCard {
            visible: StoandlClient.daemonUp
            FormCard.FormButtonDelegate {
                text: "Create support bundle"
                description: "Collect logs and diagnostics for a bug report"
                icon.name: "help-feedback-symbolic"
                onClicked: { StoandlClient.supportBundle(""); page.toast("Building support bundle…"); }
            }
        }
    }

    // Restore file picker. The chosen local file is the absolute daemon-side path (co-located GUI).
    Dialogs.FileDialog {
        id: restoreDialog
        title: "Restore from backup"
        nameFilters: ["Backup archives (*.tar *.tar.gz *.tgz *.zip)", "All files (*)"]
        onAccepted: {
            StoandlClient.restore(selectedFile);
            page.toast("Restoring…");
        }
    }
}
