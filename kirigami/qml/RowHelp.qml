import QtQuick
import org.kde.kirigami as Kirigami

/*
 * The (?) of a settings row: Kirigami.ContextualHelpButton (what KDE's System Settings uses for text
 * longer than a row's one-line description) showing `help`, and hidden while there is none. Every row
 * component (FormSwitchRow, FormOptionRow, FormTextRow, FormSpinRow, FormListRow) builds one and also
 * opens it from a long press, a right click and F1/Menu, through the functions below:
 *
 *  - show(): open the tooltip as a tap on (?) does (no hover delay; it stays until a press elsewhere).
 *  - holdStarted() / holdEnded(): a long press opens it when the finger lifts, not while it is down: a
 *    tooltip opened during the press would close again on the release (ToolTip closes on a release
 *    outside the button).
 *  - keyPressed(event): F1 or the Menu key, from the row's Keys.onPressed (a TextField passes them up).
 */
Kirigami.ContextualHelpButton {
    id: root

    property string help: ""
    property bool holdPending: false

    visible: root.help !== ""
    toolTipText: root.help

    // ContextualHelpButton's own released() handler toggles the tooltip without the hover delay.
    function show() {
        if (root.help !== "" && !root.toolTipVisible)
            root.released();
    }
    function holdStarted() { root.holdPending = root.help !== ""; }
    function holdEnded() {
        if (!root.holdPending)
            return;
        root.holdPending = false;
        root.show();
    }
    function keyPressed(event) {
        if ((event.key === Qt.Key_F1 || event.key === Qt.Key_Menu) && root.help !== "") {
            root.show();
            event.accepted = true;
        }
    }
}
