import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.stoandl.gui

// "Restart stoandl to apply: …" with Restart now, while a key set here waits for the daemon to start again
// (StoandlClient.restartPending). Restart() asks the daemon's service manager, so it works from the Flatpak
// too; the daemon refuses while a pairing window or a watch update is open (the button waits for those this
// GUI follows, StoandlClient.busyOp), or isn't a service. The list clears when the daemon goes or comes,
// which is the restart applying it.
Kirigami.InlineMessage {
    id: msg

    /** key → {label}: the schema, to name the keys. */
    property var keyInfo: ({})

    readonly property var labels: StoandlClient.restartPending.map(function (k) {
        return (msg.keyInfo[k] || { label: k }).label;
    })

    visible: StoandlClient.daemonUp && StoandlClient.restartPending.length > 0
    Layout.topMargin: Kirigami.Units.largeSpacing
    Layout.leftMargin: Kirigami.Units.largeSpacing
    Layout.rightMargin: Kirigami.Units.largeSpacing
    type: Kirigami.MessageType.Information
    text: "Restart stoandl to apply: " + msg.labels.join(", ")
          + (StoandlClient.busyOp === "pairing" ? " (after the pairing window)"
             : StoandlClient.busyOp === "firmware" ? " (after the firmware update)"
             : StoandlClient.busyOp === "language" ? " (after the language install)" : "")
    actions: [
        Kirigami.Action {
            icon.name: "view-refresh-symbolic"
            text: "Restart now"
            enabled: StoandlClient.busyOp === ""
            onTriggered: {
                var r = StoandlClient.restartDaemon();
                applicationWindow().showPassiveNotification(r.ok ? "Restarting stoandl…" : (r.tail || r.kind), r.ok ? "short" : "long");
            }
        }
    ]
}
