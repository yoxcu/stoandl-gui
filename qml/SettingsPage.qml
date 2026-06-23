import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// Settings landing page. Per KDE HIG, a settings surface this large (sync services, ~46 watch prefs,
// the daemon config, backup/diagnostics) is a list of categories that push focused sub-pages — not one
// long scroll. Each row is a FormButtonDelegate (icon + description + arrow) that opens its sub-page.
Kirigami.ScrollablePage {
    id: page
    objectName: "settings"
    // No title text — the bottom navigation already shows the section. Sub-pages keep their titles + back button.
    title: ""
    Accessible.name: "Settings"

    // Sub-pages are pushed onto the window's page stack (a back button / extra column appears).
    Component { id: syncPage;    SyncSettingsPage {} }
    Component { id: watchPage;   WatchSettingsPage {} }
    Component { id: generalPage; GeneralSettingsPage {} }
    Component { id: backupPage;  BackupSettingsPage {} }

    function open(component) { applicationWindow().pageStack.push(component); }

    ColumnLayout {
        spacing: 0

        DaemonPlaceholder {
            visible: !StoandlClient.daemonUp
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
        }

        FormCard.FormCard {
            visible: StoandlClient.daemonUp
            Layout.topMargin: Kirigami.Units.largeSpacing

            FormCard.FormButtonDelegate {
                text: "Sync"
                description: "Weather, calendar, music, health, Do Not Disturb"
                icon.name: "view-refresh-symbolic"
                onClicked: page.open(syncPage)
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormButtonDelegate {
                text: "Watch settings"
                description: "Quick launch, backlight, notifications, vibration…"
                icon.name: "chronometer-symbolic"
                onClicked: page.open(watchPage)
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormButtonDelegate {
                text: "Daemon configuration"
                description: "Units, sync providers and other stoandl options"
                icon.name: "settings-configure-symbolic"
                onClicked: page.open(generalPage)
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormButtonDelegate {
                text: "Backup & diagnostics"
                description: "Back up, restore, and collect a support bundle"
                icon.name: "document-save-symbolic"
                onClicked: page.open(backupPage)
            }
        }
    }
}
