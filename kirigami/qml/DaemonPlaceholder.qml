import QtQuick
import org.kde.kirigami as Kirigami
import org.stoandl.gui

// Shared "daemon not running" empty state. The daemon is NOT D-Bus-activated, so
// when the bus name is unowned we offer to start the systemd user service.
Kirigami.PlaceholderMessage {
    icon.name: "network-disconnect-symbolic"
    text: "stoandl daemon not running"
    explanation: "The background service that talks to your Pebble isn't running."
    helpfulAction: Kirigami.Action {
        icon.name: "media-playback-start-symbolic"
        text: "Start daemon"
        onTriggered: {
            if (StoandlClient.startDaemon())
                applicationWindow().showPassiveNotification("Starting stoandl…");
            else
                applicationWindow().showPassiveNotification("Could not launch systemctl --user start stoandl");
        }
    }
}
