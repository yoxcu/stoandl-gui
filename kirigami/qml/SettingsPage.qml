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
    title: "Settings"

    // Sub-pages are pushed onto the window's page stack (a back button / extra column appears).
    Component { id: syncPage;      SyncSettingsPage {} }
    Component { id: calendarsPage; CalendarsSettingsPage {} }
    Component { id: watchPage;     WatchSettingsPage {} }
    Component { id: healthProfilePage; HealthProfileSettingsPage {} }
    Component { id: generalPage;   GeneralSettingsPage {} }
    Component { id: backupPage;    BackupSettingsPage {} }
    Component { id: debugPage;     DebugSettingsPage {} }

    function open(component) { return applicationWindow().pageStack.push(component); }

    // Headless smoke harness (STOANDL_SMOKE_MS): instantiate every sub-page so their reload() paths —
    // and therefore every schema-driven widget kind — actually run under `QT_QPA_PLATFORM=offscreen`,
    // then run a sub-page's own smokeExercise() for state only a button reaches (Debug → Heartbeat).
    // The sub-pages are page-scoped Components, so Main.qml drives this through the page, not directly.
    function smokeExercise() {
        var pages = [syncPage, calendarsPage, watchPage, healthProfilePage, generalPage, backupPage, debugPage];
        for (var i = 0; i < pages.length; ++i) {
            var sub = page.open(pages[i]);
            if (sub && typeof sub.smokeExercise === "function")
                sub.smokeExercise();
        }
        console.log("stoandl-smoke: exercised " + pages.length + " settings sub-pages");
    }

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
                text: "Calendars"
                description: "CalDAV accounts, iCal feeds and local calendars"
                icon.name: "view-calendar-symbolic"
                onClicked: page.open(calendarsPage)
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
                text: "Health profile"
                description: "Height, weight, age, units and heart-rate tracking"
                icon.name: "stoandl-heart-symbolic"
                onClicked: page.open(healthProfilePage)
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
            FormCard.FormDelegateSeparator {}
            FormCard.FormButtonDelegate {
                text: "Debug"
                description: "Diagnostics, recovery and other low-level tools"
                icon.name: "tools-report-bug-symbolic"
                onClicked: page.open(debugPage)
            }
        }
    }
}
