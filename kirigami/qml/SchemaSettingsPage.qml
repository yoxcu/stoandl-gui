import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// One Settings page of stoandl.conf keys (Notifications, Weather, …): SchemaSections for `pageName`, and a
// "Sync now" action where the page holds a service that can sync on demand (weather, calendar, health).
Kirigami.ScrollablePage {
    id: page
    objectName: "schemaSettings"
    title: page.pageName

    /** The schema's `page` column. */
    property string pageName: ""
    /** A key to scroll to and highlight (the Settings search); "" = none. */
    property string focusKey: ""

    // The service on this page that SyncWeather / SyncCalendar / SyncHealth refresh, if any.
    readonly property string syncService: {
        for (var k in sections.syncByKey) {
            var s = sections.syncByKey[k].service;
            if (sections.cfgFields[k] && (s === "weather" || s === "calendar" || s === "health"))
                return s;
        }
        return "";
    }

    function syncNow() {
        var label = sections.keyInfo[sections.serviceKey(page.syncService)].label;
        var r = page.syncService === "weather" ? StoandlClient.syncWeather()
              : page.syncService === "calendar" ? StoandlClient.syncCalendar()
              : StoandlClient.syncHealth();
        applicationWindow().showPassiveNotification(r.ok ? label + " synced" : label + ": " + (r.tail || r.kind));
        sections.applySync(StoandlClient.getSyncStatus());   // the master row's "Last sync"
        sections.updateRows();
    }

    function smokeExercise() { sections.smokeExercise(); }

    actions: [
        Kirigami.Action {
            icon.name: "view-refresh-symbolic"
            text: "Sync now"
            visible: page.syncService !== ""
            enabled: StoandlClient.daemonUp
            onTriggered: page.syncNow()
        }
    ]

    ColumnLayout {
        spacing: 0

        DaemonPlaceholder {
            visible: !StoandlClient.daemonUp
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
        }

        SchemaSections {
            id: sections
            visible: StoandlClient.daemonUp
            Layout.fillWidth: true
            pageName: page.pageName
            focusKey: page.focusKey
            flickable: page.flickable
        }
    }
}
