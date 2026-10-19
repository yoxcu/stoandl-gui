import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

// One "are you sure?" for an action that can't be undone from here (Main.confirm() opens the window's one
// instance): the question, the action's own name on its button, and Cancel. Actions that can be put back
// act at once and offer Undo on their toast instead.
Kirigami.PromptDialog {
    id: dialog

    property string actionText: ""
    property string actionIcon: ""
    property var _onConfirm: null

    standardButtons: QQC2.Dialog.NoButton
    preferredWidth: applicationWindow().dialogWidth(24)

    function ask(heading, text, actionText, actionIcon, onConfirm) {
        dialog.title = heading;
        dialog.subtitle = text;
        dialog.actionText = actionText;
        dialog.actionIcon = actionIcon || "dialog-ok-symbolic";
        dialog._onConfirm = onConfirm;
        dialog.open();
    }

    customFooterActions: [
        Kirigami.Action {
            text: dialog.actionText
            icon.name: dialog.actionIcon
            onTriggered: {
                var fn = dialog._onConfirm;
                dialog._onConfirm = null;
                dialog.close();
                if (fn)
                    fn();
            }
        },
        Kirigami.Action {
            text: "Cancel"
            icon.name: "dialog-cancel-symbolic"
            onTriggered: dialog.close()
        }
    ]
}
