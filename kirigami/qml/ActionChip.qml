import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

// A status chip with its own fix: "Forwarding off  [Turn on]". Kirigami.Chip draws the pill; its trailing
// button (the slot a closable chip's Remove sits in) carries `actionText` and emits `triggered`. A click
// on the chip itself is the Chip's own `clicked`, for the page to take the user to the full control.
Kirigami.Chip {
    id: chip

    property string actionText
    property string actionIcon: "media-playback-start-symbolic"
    signal triggered()

    checkable: false
    closable: true   // reserves the trailing slot the action button sits in
    Accessible.description: chip.actionText

    indicator: QQC2.ToolButton {
        x: chip.mirrored ? 0 : parent.width - width
        y: Math.round((parent.height - height) / 2)
        visible: chip.closable
        text: chip.actionText
        icon.name: chip.actionIcon
        icon.width: Kirigami.Units.iconSizes.sizeForLabels
        icon.height: Kirigami.Units.iconSizes.sizeForLabels
        display: QQC2.AbstractButton.TextBesideIcon
        onClicked: chip.triggered()
    }
}
