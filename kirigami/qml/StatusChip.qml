import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

// A small, non-interactive status/flag pill (e.g. "active", "system").
Rectangle {
    id: chip

    property string label
    property color tint: Kirigami.Theme.disabledTextColor

    implicitWidth: chipLabel.implicitWidth + Kirigami.Units.largeSpacing * 2
    implicitHeight: chipLabel.implicitHeight + Kirigami.Units.smallSpacing
    radius: height / 2
    color: Qt.rgba(tint.r, tint.g, tint.b, 0.15)
    border.width: 1
    border.color: Qt.rgba(tint.r, tint.g, tint.b, 0.5)

    QQC2.Label {
        id: chipLabel
        anchors.centerIn: parent
        text: chip.label
        color: chip.tint
        font: Kirigami.Theme.smallFont
    }
}
