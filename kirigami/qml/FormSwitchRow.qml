import QtQuick
import org.kde.kirigamiaddons.formcard as FormCard

/*
 * FormCard.FormSwitchDelegate with the settings rows' help: a (?) at the trailing edge (RowHelp) when
 * `help` is set, also opened by a long press, a right click or F1. A long press doesn't flip the switch:
 * with pressAndHold connected, the button sends no click after a hold.
 *
 * `checked` still can't be bound (the delegate assigns it from its inner Switch, which drops the
 * binding), so a row follows its value from a Connections handler, as before.
 */
FormCard.FormSwitchDelegate {
    id: root

    /** Longer text behind the (?) button; empty = no button. */
    property string help: ""

    // Only when there is help: an empty trailing item still takes its width.
    trailing: root.help !== "" ? helpButton : null
    Accessible.description: root.description + (root.help !== "" ? " " + root.help : "")

    // Only a hold on the row itself: the inner Switch forwards its own hold, but not its release.
    onPressAndHold: if (root.pressed) helpButton.holdStarted()
    onReleased: helpButton.holdEnded()
    onCanceled: helpButton.holdPending = false
    Keys.onPressed: (event) => helpButton.keyPressed(event)

    TapHandler {
        acceptedButtons: Qt.RightButton
        onTapped: helpButton.show()
    }

    RowHelp {
        id: helpButton
        help: root.help
    }
}
