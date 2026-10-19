import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.stoandl.gui

// "Forwarding is off" with Turn on, while notification.forward is off (StoandlClient.forwarding). Shown on
// the Alerts tab (the Watch tab has a chip with the same fix); the key's own control is the first row of
// Settings → Notifications.
Kirigami.InlineMessage {
    id: banner

    function turnOn() { applicationWindow().turnOnForwarding(); }

    visible: StoandlClient.daemonUp && !StoandlClient.forwarding
    Layout.topMargin: Kirigami.Units.largeSpacing
    Layout.leftMargin: Kirigami.Units.largeSpacing
    Layout.rightMargin: Kirigami.Units.largeSpacing
    type: Kirigami.MessageType.Warning
    icon.source: "notifications-disabled-symbolic"
    text: "Forwarding is off: notifications stay on this device. Calls still ring on the watch."
    actions: [
        Kirigami.Action {
            icon.name: "notifications-symbolic"
            text: "Turn on"
            onTriggered: banner.turnOn()
        }
    ]
}
