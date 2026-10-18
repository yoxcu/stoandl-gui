import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import "ConfList.js" as ConfList

/*
 * A list-valued setting as one editable row per item, with move up/down, remove and an add field.
 * `value` is the daemon's encoded list (ConfList.js), so an item may contain a comma; every edit emits
 * the whole re-encoded list through commit() — the caller writes it and feeds the stored value back.
 * When that stored value comes back unchanged (the daemon refused the edit), the item rows are rebuilt
 * from it anyway, so a refused edit doesn't stay in its field.
 */
FormCard.AbstractFormDelegate {
    id: root

    property string label: ""
    property string description: ""
    /** The encoded list, as GetConfig reports it. */
    property string value: ""
    /** Shape hint for the add field (the schema's placeholder). */
    property string placeholderText: ""

    signal commit(string value)

    readonly property var items: ConfList.decode(root.value)

    function emitWith(list) {
        var v = ConfList.encode(list);
        if (v === root.value) return;
        var before = root.value;
        root.commit(v);
        if (root.value === before)
            itemRepeater.model = Qt.binding(function () { return ConfList.decode(root.value); });
    }
    function setAt(i, text) { var l = root.items.slice(); l[i] = text; root.emitWith(l); }
    function removeAt(i) { var l = root.items.slice(); l.splice(i, 1); root.emitWith(l); }
    function move(i, d) {
        var l = root.items.slice();
        var t = l[i]; l[i] = l[i + d]; l[i + d] = t;
        root.emitWith(l);
    }
    function add(text) {
        if (text.trim() === "") return;
        root.emitWith(root.items.concat([text]));
    }

    background: null
    Layout.fillWidth: true

    contentItem: ColumnLayout {
        spacing: Kirigami.Units.smallSpacing

        QQC2.Label {
            Layout.fillWidth: true
            visible: root.label !== ""
            text: root.label
            elide: Text.ElideRight
        }

        QQC2.Label {
            Layout.fillWidth: true
            visible: root.description !== ""
            text: root.description
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            color: Kirigami.Theme.disabledTextColor
        }

        Repeater {
            id: itemRepeater
            model: root.items
            delegate: RowLayout {
                id: itemRow
                required property var modelData
                required property int index
                Layout.fillWidth: true
                spacing: 0

                // Commit on focus-out / Enter only: the commit rebuilds the rows.
                QQC2.TextField {
                    id: itemField
                    Layout.fillWidth: true
                    text: itemRow.modelData
                    onEditingFinished: {
                        if (itemField.text !== itemRow.modelData) root.setAt(itemRow.index, itemField.text);
                    }
                }
                QQC2.ToolButton {
                    visible: root.items.length > 1
                    enabled: itemRow.index > 0
                    icon.name: "go-up-symbolic"
                    display: QQC2.AbstractButton.IconOnly
                    text: "Move up"
                    QQC2.ToolTip.text: text
                    QQC2.ToolTip.visible: hovered
                    onClicked: root.move(itemRow.index, -1)
                }
                QQC2.ToolButton {
                    visible: root.items.length > 1
                    enabled: itemRow.index < root.items.length - 1
                    icon.name: "go-down-symbolic"
                    display: QQC2.AbstractButton.IconOnly
                    text: "Move down"
                    QQC2.ToolTip.text: text
                    QQC2.ToolTip.visible: hovered
                    onClicked: root.move(itemRow.index, 1)
                }
                QQC2.ToolButton {
                    icon.name: "edit-delete-symbolic"
                    display: QQC2.AbstractButton.IconOnly
                    text: "Remove"
                    QQC2.ToolTip.text: text
                    QQC2.ToolTip.visible: hovered
                    onClicked: root.removeAt(itemRow.index)
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 0

            QQC2.TextField {
                id: addField
                Layout.fillWidth: true
                placeholderText: root.placeholderText !== ""
                    ? "Add an item (e.g. " + ConfList.decode(root.placeholderText)[0] + ")" : "Add an item"
                onAccepted: { root.add(addField.text); addField.text = ""; }
            }
            QQC2.ToolButton {
                enabled: addField.text.trim() !== ""
                icon.name: "list-add"
                display: QQC2.AbstractButton.IconOnly
                text: "Add"
                QQC2.ToolTip.text: text
                QQC2.ToolTip.visible: hovered
                onClicked: { root.add(addField.text); addField.text = ""; }
            }
        }
    }
}
