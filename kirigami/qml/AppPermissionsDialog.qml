import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.stoandl.gui

// One app's permissions (PermList): each with its effective status and last use, Allow / Deny for the
// undecided, a switch for the decided, Reset back to undecided, and "Ask later" for waiting requests.
Kirigami.Dialog {
    id: dialog

    property string appUuid: ""
    property string appTitle: ""
    property bool pluginsOn: true
    property var rows: []
    // Waiting requests not yet put off (PermPending's seen flag), which "Ask later" applies to.
    property int unseenWaiting: 0

    title: appTitle !== "" ? appTitle + " · Permissions" : "Permissions"
    preferredWidth: applicationWindow().dialogWidth(28)
    standardButtons: QQC2.Dialog.Close
    showCloseButton: true

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    function openFor(uuid, title, pluginsOn) {
        dialog.appUuid = uuid;
        dialog.appTitle = title;
        dialog.pluginsOn = pluginsOn;
        reload();
        open();
    }

    function reload() {
        if (!StoandlClient.daemonUp || appUuid === "") { rows = []; unseenWaiting = 0; return; }
        rows = StoandlClient.permList(appUuid);
        unseenWaiting = StoandlClient.permPending().filter(function (r) {
            return r.appUuid === dialog.appUuid && !r.seen;
        }).length;
    }

    function decide(key, decision) {
        var r = StoandlClient.permSet(appUuid, key, decision);
        if (!r.ok) toast("Couldn't " + decision + ": " + (r.tail || r.kind));
        reload();
        StoandlClient.refreshPlugins();
    }

    function statusText(status) {
        switch (status) {
        case "granted": return "Allowed";
        case "denied":  return "Denied";
        case "auto":    return "Allowed automatically";
        case "waiting": return "Waiting for your answer";
        case "blocked": return "Blocked";
        }
        return status;
    }

    function ago(ms) {
        if (!ms) return "not used yet";
        var s = Math.max(0, (Date.now() - ms) / 1000);
        if (s < 90) return "used just now";
        if (s < 5400) return "used " + Math.round(s / 60) + " min ago";
        if (s < 129600) return "used " + Math.round(s / 3600) + " h ago";
        return "used " + Math.round(s / 86400) + " days ago";
    }

    Connections {
        target: StoandlClient
        enabled: dialog.visible
        function onPermissionRequestsChanged(rows) { dialog.reload(); }
    }

    ColumnLayout {
        spacing: 0
        Layout.preferredWidth: applicationWindow().dialogWidth(28)

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            visible: !dialog.pluginsOn
            type: Kirigami.MessageType.Information
            text: "Plugins are off (Settings → Apps & plugins), so apps aren't asked and everything is allowed."
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            visible: dialog.unseenWaiting > 0
            type: Kirigami.MessageType.Warning
            text: dialog.appTitle + " is waiting for an answer. Until then it's refused."
            actions: [
                Kirigami.Action {
                    text: "Ask later"
                    icon.name: "appointment-soon-symbolic"
                    tooltip: "Stop the prompts and banners for now, without deciding"
                    onTriggered: dialog.decide("", "later")
                }
            ]
        }

        QQC2.Label {
            visible: dialog.rows.length === 0
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.largeSpacing
            wrapMode: Text.WordWrap
            opacity: 0.7
            text: "This app hasn't asked for any permission."
        }

        Repeater {
            model: dialog.rows
            delegate: ColumnLayout {
                id: permRow
                required property var modelData
                required property int index
                readonly property bool decided: modelData.status === "granted" || modelData.status === "denied"
                readonly property bool undecided: modelData.status === "auto" || modelData.status === "waiting"
                Layout.fillWidth: true
                spacing: 0

                Kirigami.Separator { Layout.fillWidth: true; visible: permRow.index > 0 }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.margins: Kirigami.Units.largeSpacing
                    spacing: Kirigami.Units.largeSpacing

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        QQC2.Label {
                            Layout.fillWidth: true
                            text: permRow.modelData.label
                            wrapMode: Text.WordWrap
                        }
                        QQC2.Label {
                            Layout.fillWidth: true
                            text: dialog.statusText(permRow.modelData.status) + " · " + dialog.ago(permRow.modelData.lastUsed)
                            color: permRow.modelData.status === "waiting" ? Kirigami.Theme.neutralTextColor
                                 : permRow.modelData.status === "denied" || permRow.modelData.status === "blocked"
                                   ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
                            font: Kirigami.Theme.smallFont
                            opacity: 0.8
                            wrapMode: Text.WordWrap
                        }
                        QQC2.Label {
                            Layout.fillWidth: true
                            text: permRow.modelData.key
                            font.family: "monospace"
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            opacity: 0.5
                            elide: Text.ElideRight
                        }
                    }

                    QQC2.Switch {
                        visible: permRow.decided
                        checked: permRow.modelData.status === "granted"
                        QQC2.ToolTip.text: checked ? "Deny" : "Allow"
                        QQC2.ToolTip.visible: hovered
                        onToggled: dialog.decide(permRow.modelData.key, checked ? "allow" : "deny")
                    }
                    QQC2.ToolButton {
                        visible: permRow.undecided
                        icon.name: "dialog-cancel-symbolic"
                        display: QQC2.AbstractButton.IconOnly
                        QQC2.ToolTip.text: "Deny"
                        QQC2.ToolTip.visible: hovered
                        onClicked: dialog.decide(permRow.modelData.key, "deny")
                    }
                    QQC2.ToolButton {
                        visible: permRow.undecided
                        icon.name: "dialog-ok-apply-symbolic"
                        display: QQC2.AbstractButton.IconOnly
                        QQC2.ToolTip.text: "Allow"
                        QQC2.ToolTip.visible: hovered
                        onClicked: dialog.decide(permRow.modelData.key, "allow")
                    }
                    QQC2.ToolButton {
                        visible: !permRow.undecided
                        icon.name: "edit-undo-symbolic"
                        display: QQC2.AbstractButton.IconOnly
                        QQC2.ToolTip.text: "Reset: undecided, the app asks again"
                        QQC2.ToolTip.visible: hovered
                        onClicked: dialog.decide(permRow.modelData.key, "reset")
                    }
                }
            }
        }
    }
}
