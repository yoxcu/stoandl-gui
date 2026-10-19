import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard

/*
 * An on/off setting row for a FormCard: what FormCard.FormSwitchDelegate shows (the name, the
 * description under it, a switch), plus the settings rows' help: a (?) at the trailing edge (RowHelp)
 * when `help` is set, also opened by a long press, a right click or F1. A long press doesn't flip the
 * switch: with pressAndHold connected, the row sends no click after a hold.
 *
 * Not FormSwitchDelegate because its inner Switch follows only the delegate's `enabled`, and a row
 * whose prerequisite is off must keep its (?) working: `locked` turns off the switch and the row's
 * toggle and nothing else. (`enabled: false` would disable the help with it.)
 *
 * `checked` can be bound for the initial value, but a toggle assigns it, which drops the binding, so a
 * row that follows a re-read value does it from a Connections handler.
 */
FormCard.AbstractFormDelegate {
    id: root

    property string description: ""
    /** Longer text behind the (?) button; empty = no button. */
    property string help: ""
    /** The value can't be changed now (a setting it depends on is off); the help still opens. */
    property bool locked: false

    checkable: !root.locked
    Accessible.role: Accessible.CheckBox
    Accessible.name: root.text
    Accessible.description: root.description + (root.help !== "" ? " " + root.help : "")
    Accessible.onPressAction: if (!root.locked) { root.toggle(); root.toggled(); }
    Accessible.onToggleAction: if (!root.locked) { root.toggle(); root.toggled(); }

    // Only a hold on the row itself: the Switch takes its own presses.
    onPressAndHold: helpButton.holdStarted()
    onReleased: helpButton.holdEnded()
    onCanceled: helpButton.holdPending = false
    Keys.onPressed: (event) => helpButton.keyPressed(event)

    TapHandler {
        acceptedButtons: Qt.RightButton
        onTapped: helpButton.show()
    }

    contentItem: RowLayout {
        spacing: 0

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            QQC2.Label {
                Layout.fillWidth: true
                text: root.text
                elide: Text.ElideRight
                wrapMode: Text.Wrap
                maximumLineCount: 2
                color: root.enabled && !root.locked ? Kirigami.Theme.textColor : Kirigami.Theme.disabledTextColor
                Accessible.ignored: true
            }

            QQC2.Label {
                visible: root.description !== ""
                Layout.fillWidth: true
                text: root.description
                wrapMode: Text.Wrap
                color: Kirigami.Theme.disabledTextColor
                Accessible.ignored: true
            }
        }

        QQC2.Switch {
            focusPolicy: Qt.NoFocus // the row takes focus
            Layout.leftMargin: Kirigami.Units.largeSpacing
            enabled: !root.locked
            checked: root.checked
            spacing: 0
            contentItem: null
            topPadding: 0
            leftPadding: 0
            rightPadding: 0
            bottomPadding: 0
            // The Switch flips itself (dropping its binding): hand the value to the row and follow it again.
            onToggled: {
                root.checked = checked;
                checked = Qt.binding(() => root.checked);
                root.toggled();
            }
            Accessible.ignored: true
        }

        RowHelp {
            id: helpButton
            Layout.leftMargin: visible ? Kirigami.Units.smallSpacing : 0
            help: root.help
        }
    }
}
