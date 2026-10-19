import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard

/*
 * A one-of-several setting row for a FormCard: the setting's name, its current value and a down
 * arrow, with the description underneath — what FormCard.FormComboBoxDelegate shows in its mobile
 * Dialog mode, without the cost. Clicking it emits `clicked`; the page opens its one OptionPicker.
 *
 * Not FormComboBoxDelegate because that builds a hidden QQC2.ComboBox (with a delegate per option in
 * its popup) and an InlineMessage for every row, whatever the display mode: ~10 ms a row on x86, and
 * the settings pages have dozens. This row holds two or three Labels and an icon.
 *
 * The value is display-only: bind it to the stored value. A pick goes to the daemon and the re-read
 * moves the binding, so a refused value never shows here.
 */
FormCard.AbstractFormDelegate {
    id: root

    property string description: ""
    /** The current value's label, shown at the trailing edge. */
    property string value: ""
    /** Extra items placed before the value (e.g. a colour swatch). */
    default property alias trailing: trailingSlot.data

    Accessible.role: Accessible.ComboBox
    Accessible.name: root.text
    Accessible.description: root.value + (root.description !== "" ? ". " + root.description : "")
    Accessible.onPressAction: root.clicked()
    Keys.onReturnPressed: root.clicked()
    Keys.onEnterPressed: root.clicked()

    contentItem: ColumnLayout {
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            QQC2.Label {
                Layout.fillWidth: true
                text: root.text
                elide: Text.ElideRight
                wrapMode: Text.Wrap
                maximumLineCount: 2
                color: root.enabled ? Kirigami.Theme.textColor : Kirigami.Theme.disabledTextColor
                Accessible.ignored: true
            }

            RowLayout {
                id: trailingSlot
                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                spacing: Kirigami.Units.smallSpacing
                visible: children.length > 0
            }

            QQC2.Label {
                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                Layout.maximumWidth: Math.round(root.width / 2)
                Layout.rightMargin: Kirigami.Units.smallSpacing
                text: root.value
                elide: Text.ElideRight
                color: Kirigami.Theme.disabledTextColor
                Accessible.ignored: true
            }

            FormCard.FormArrow {
                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                direction: Qt.DownArrow
            }
        }

        QQC2.Label {
            Layout.fillWidth: true
            visible: root.description !== ""
            text: root.description
            wrapMode: Text.Wrap
            color: Kirigami.Theme.disabledTextColor
            Accessible.ignored: true
        }
    }
}
