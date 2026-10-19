import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.components as Components

/*
 * The one-of-several picker behind FormOptionRow: a dialog listing the options, the stored one checked.
 * A settings page holds ONE of these, created on first use (a Loader), and every option row opens it
 * with its own title, options and callback — instead of every row carrying a hidden combo box.
 *
 *     picker.choose("Language", ["English", "Deutsch"], 1, function (index, text) { … });
 *
 * The callback runs once, as the dialog closes, with the picked index and option text; closing it any
 * other way (Escape, a tap outside) picks nothing. Picking the stored option still calls back, as a
 * combo box's `activated` does.
 *
 * It is the dialog FormComboBoxDelegate opens in its mobile mode (same frame, heading and sizing), with
 * radio marks for the stored value. Not a Kirigami.Dialog: that one sizes a non-ListView content from
 * its implicit height once, at creation, while this list is empty until the first choose().
 *
 * Keyboard: the list has focus on the stored option; Up/Down move, Enter/Return/Space pick.
 */
QQC2.Dialog {
    id: picker

    property var options: []
    /** The index shown as checked; -1 = none (e.g. a colour whose value is not one of the presets). */
    property int currentIndex: -1
    property var _onPicked: null

    function choose(title, options, currentIndex, onPicked) {
        picker.title = title;
        picker.options = options || [];
        picker.currentIndex = currentIndex;
        picker._onPicked = onPicked;   // a reopen while open replaces the earlier caller
        list.currentIndex = currentIndex >= 0 ? currentIndex : 0;
        picker.open();
    }

    function pick(index) {
        var fn = picker._onPicked;
        picker._onPicked = null;
        picker.close();
        if (fn && index >= 0 && index < picker.options.length)
            fn(index, picker.options[index]);
    }

    parent: applicationWindow().overlay
    x: Math.round((parent.width - width) / 2)
    y: Math.round((parent.height - height) / 2)
    z: Kirigami.OverlayZStacking.z
    implicitWidth: Math.min(parent.width - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 22)
    implicitHeight: Math.min(
        Math.max(implicitBackgroundHeight + topInset + bottomInset,
                 contentHeight + topPadding + bottomPadding
                 + (implicitHeaderHeight > 0 ? implicitHeaderHeight + spacing : 0)
                 + (implicitFooterHeight > 0 ? implicitFooterHeight + spacing : 0)),
        parent.height - Kirigami.Units.gridUnit * 2)
    background: Components.DialogRoundedBackground {}
    modal: true
    focus: true
    padding: 0

    onOpened: {
        list.positionViewAtIndex(list.currentIndex, ListView.Contain);
        list.forceActiveFocus();
    }
    onClosed: picker._onPicked = null

    header: Kirigami.Heading {
        text: picker.title
        elide: QQC2.Label.ElideRight
        leftPadding: Kirigami.Units.largeSpacing
        rightPadding: Kirigami.Units.largeSpacing
        topPadding: Kirigami.Units.largeSpacing
        bottomPadding: Kirigami.Units.largeSpacing
    }

    contentItem: QQC2.ScrollView {
        Component.onCompleted: if (background) background.visible = false;

        ListView {
            id: list
            clip: true
            model: picker.options
            keyNavigationEnabled: true
            Keys.onReturnPressed: picker.pick(list.currentIndex)
            Keys.onEnterPressed: picker.pick(list.currentIndex)
            Keys.onSpacePressed: picker.pick(list.currentIndex)

            delegate: QQC2.RadioDelegate {
                required property var modelData
                required property int index
                width: ListView.view.width
                text: modelData
                // Shows the stored value; a click picks (and closes) rather than toggling.
                checkable: false
                checked: index === picker.currentIndex
                highlighted: ListView.isCurrentItem && ListView.view.activeFocus
                focusPolicy: Qt.NoFocus
                onClicked: picker.pick(index)
            }
        }
    }
}
