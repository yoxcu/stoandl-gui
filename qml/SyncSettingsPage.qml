import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// Sync services: per-service master on/off (GetSyncStatus / SetSyncEnabled), inline force-sync for the
// three pull services, and the per-calendar toggles nested underneath. Notifications are deliberately
// absent — they live on the Notifications tab.
Kirigami.ScrollablePage {
    id: page
    objectName: "syncSettings"
    title: "Sync"

    property var syncStatus: []   // [{service,enabled,available,lastSync}]
    property var calendars: []    // [{id,name,enabled}]

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    readonly property var syncServices: page.syncStatus.filter(function (s) { return s.service !== "notifications"; })

    function serviceLabel(service) {
        if (service === "weather")  return "Weather";
        if (service === "calendar") return "Calendar";
        if (service === "music")    return "Music";
        if (service === "health")   return "Health";
        if (service === "dnd")      return "Do Not Disturb";
        return service;
    }
    function serviceIcon(service) {
        if (service === "weather")  return "weather-clear-symbolic";
        if (service === "calendar") return "view-calendar-symbolic";
        if (service === "music")    return "media-playback-start-symbolic";
        if (service === "health")   return "love-symbolic";
        if (service === "dnd")      return "notifications-disabled-symbolic";
        return "emblem-synchronizing-symbolic";
    }

    function reload() {
        if (!StoandlClient.daemonUp) { page.syncStatus = []; page.calendars = []; return; }
        page.syncStatus = StoandlClient.getSyncStatus();
        StoandlClient.refreshCalendars();
    }

    function toggleSync(service, on) {
        var r = StoandlClient.setSyncEnabled(service, on);
        if (!r.ok) page.toast(page.serviceLabel(service) + ": " + (r.tail || r.kind));
        page.syncStatus = StoandlClient.getSyncStatus();
    }

    function forceSync(fn, label) {
        var r = fn();
        page.toast(r.ok ? (label + " synced") : (label + ": " + (r.tail !== "" ? r.tail : r.kind)));
        page.syncStatus = StoandlClient.getSyncStatus();   // a force-sync updates the lastSync label
    }

    function syncAll() {
        page.forceSync(StoandlClient.syncWeather, "Weather");
        page.forceSync(StoandlClient.syncCalendar, "Calendar");
        page.forceSync(StoandlClient.syncHealth, "Health");
    }

    function toggleCalendar(id, on) {
        var r = StoandlClient.setCalendarEnabled(id, on);
        if (!r.ok) page.toast("Calendar: " + (r.tail || r.kind));
        StoandlClient.refreshCalendars();
    }

    Connections {
        target: StoandlClient
        function onCalendarsChanged(rows) { page.calendars = rows; }
        function onDaemonUpChanged() { if (StoandlClient.daemonUp) page.reload(); }
    }

    Component.onCompleted: page.reload()

    actions: [
        Kirigami.Action {
            icon.name: "view-refresh-symbolic"
            text: "Sync all now"
            enabled: StoandlClient.daemonUp
            onTriggered: page.syncAll()
        }
    ]

    ColumnLayout {
        spacing: 0

        DaemonPlaceholder {
            visible: !StoandlClient.daemonUp
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
        }

        // --- Services on/off ----------------------------------------------
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp
            title: "Services"
        }
        FormCard.FormCard {
            visible: StoandlClient.daemonUp
            Repeater {
                model: page.syncServices
                delegate: FormCard.FormSwitchDelegate {
                    required property var modelData
                    icon.name: page.serviceIcon(modelData.service)
                    text: page.serviceLabel(modelData.service)
                    description: "Last sync · " + (modelData.lastSync || "never")
                    enabled: modelData.available !== false
                    checked: modelData.enabled === true
                    onToggled: page.toggleSync(modelData.service, checked)
                }
            }
        }

        // --- Force-sync now -----------------------------------------------
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp
            title: "Sync now"
        }
        FormCard.FormCard {
            visible: StoandlClient.daemonUp
            FormCard.FormButtonDelegate {
                text: "Weather"
                icon.name: "weather-clear-symbolic"
                onClicked: page.forceSync(StoandlClient.syncWeather, "Weather")
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormButtonDelegate {
                text: "Calendar"
                icon.name: "view-calendar-symbolic"
                onClicked: page.forceSync(StoandlClient.syncCalendar, "Calendar")
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormButtonDelegate {
                text: "Health"
                icon.name: "love-symbolic"
                onClicked: page.forceSync(StoandlClient.syncHealth, "Health")
            }
        }

        // --- Calendars (nested under Sync) --------------------------------
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp && page.calendars.length > 0
            title: "Calendars"
        }
        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.calendars.length > 0
            Repeater {
                model: page.calendars
                delegate: FormCard.FormSwitchDelegate {
                    required property var modelData
                    text: modelData.name
                    checked: modelData.enabled === true
                    onToggled: page.toggleCalendar(modelData.id, checked)
                }
            }
        }
    }
}
