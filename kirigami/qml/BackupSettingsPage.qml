import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs as Dialogs
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// Backup and restore. These are CLI-local (`stoandl backup|restore` over ~/.config/stoandl) — NOT D-Bus
// methods — so they shell out to the co-located binary and report back via cliResult. (The support
// bundle, the third CLI-local tool, is on Diagnostics & developer.)
Kirigami.ScrollablePage {
    id: page
    objectName: "backupSettings"
    title: "Backup & restore"

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    Connections {
        target: StoandlClient
        function onCliResult(op, ok, message) {
            if (op === "backup")
                page.toast(ok ? "Backup complete" : ("Backup failed: " + message));
            else if (op === "restore")
                page.toast(ok ? "Restore complete" : ("Restore failed: " + message));
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
                text: "Back up now…"
                description: "Save a full backup of the watch and daemon state"
                icon.name: "document-save-symbolic"
                onClicked: backupDialog.openWithName()
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormButtonDelegate {
                text: "Restore from file…"
                description: "Restore a previously saved backup"
                icon.name: "document-open-symbolic"
                onClicked: restoreDialog.open()
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

    // Save pickers: the user chooses where the archive lands (so they know where it is), and the chosen
    // absolute path is passed to the daemon-side CLI. Blank path (dialog cancelled) is never sent.
    SaveFileDialog {
        id: backupDialog
        fileName: "stoandl-backup.tar.gz"
        title: "Save backup as"
        nameFilters: ["Backup archives (*.tar.gz *.tgz)", "All files (*)"]
        onAccepted: {
            StoandlClient.backup(selectedFile);
            page.toast("Backing up…");
        }
    }
}
