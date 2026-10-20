import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.stoandl.gui

// The watch screenshot the daemon just saved (a watch task; Main.qml opens this on its result): the picture
// at a whole multiple of its size (the watch's pixels stay sharp), where it was saved, and Open / Open folder /
// Take another. Take another starts the next task; its result replaces the picture here.
Kirigami.Dialog {
    id: dialog

    property string path: ""
    property int shotWidth: 0
    property int shotHeight: 0
    readonly property bool taking: "screenshot" in StoandlClient.tasks

    title: "Watch screenshot"
    preferredWidth: applicationWindow().dialogWidth(20)
    standardButtons: QQC2.Dialog.Close
    showCloseButton: true

    function show(result) {
        dialog.path = result.path;
        dialog.shotWidth = result.width;
        dialog.shotHeight = result.height;
        if (!dialog.opened)
            dialog.open();
    }

    customFooterActions: [
        Kirigami.Action {
            text: "Open"
            icon.name: "document-open-symbolic"
            enabled: dialog.path !== ""
            onTriggered: applicationWindow().openSaved(dialog.path, false)
        },
        Kirigami.Action {
            text: "Open folder"
            icon.name: "folder-open-symbolic"
            enabled: dialog.path !== ""
            onTriggered: applicationWindow().openSaved(dialog.path, true)
        },
        Kirigami.Action {
            text: "Take another"
            icon.name: "camera-photo-symbolic"
            enabled: !dialog.taking
            onTriggered: {
                var r = StoandlClient.takeScreenshot();
                if (!r.ok)
                    applicationWindow().showPassiveNotification("Screenshot: " + (r.tail || r.kind), "long");
            }
        }
    ]

    ColumnLayout {
        spacing: Kirigami.Units.largeSpacing

        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: shot.height
            Image {
                id: shot
                anchors.horizontalCenter: parent.horizontalCenter
                // The largest whole multiple of the watch's resolution that fits (at least 1×).
                readonly property int zoom: Math.max(1, Math.floor(Math.min(parent.width / Math.max(1, dialog.shotWidth),
                                                                         Kirigami.Units.gridUnit * 18 / Math.max(1, dialog.shotHeight))))
                width: dialog.shotWidth * zoom
                height: dialog.shotHeight * zoom
                source: dialog.path !== "" ? encodeURI("file://" + dialog.path) : ""
                smooth: false
                cache: false
                fillMode: Image.PreserveAspectFit
                opacity: dialog.taking ? 0.4 : 1
            }
            // A file this GUI can't read (a Flatpak without the folder shared): say so in place of the picture.
            QQC2.Label {
                anchors.fill: shot
                visible: shot.status === Image.Error && !dialog.taking
                text: "Saved, but this app can't show it"
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                wrapMode: Text.WordWrap
                opacity: 0.7
            }
            QQC2.BusyIndicator {
                anchors.centerIn: shot
                running: dialog.taking
                visible: running
            }
        }
        QQC2.Label {
            Layout.fillWidth: true
            text: dialog.path
            wrapMode: Text.WrapAnywhere
            font: Kirigami.Theme.smallFont
            opacity: 0.7
        }
    }
}
