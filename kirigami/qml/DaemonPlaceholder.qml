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
        // Async (reset-failed, then start): a failure arrives as daemonStartFailed, which Main.qml
        // reports once — this placeholder is instantiated on every page.
        onTriggered: {
            StoandlClient.startDaemon();
            applicationWindow().showPassiveNotification("Starting stoandl…");
        }
    }
}
