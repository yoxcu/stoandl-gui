import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard

/*
 * A bounded-number row for a FormCard, with a unit and a debounced commit — the sibling of
 * FormTextRow.qml.
 *
 * Not FormCard.FormSpinBoxDelegate because that has no `description` property, and every schema-driven
 * settings row on this interface carries one.
 *
 * The debounce is the point of sharing this: a spin box fires valueChanged on every step and on
 * auto-repeat, and both callers respond by re-fetching and rebuilding the very control being dragged.
 * So `commit` is emitted once, ~500 ms after the user stops — never per tick.
 */
FormCard.AbstractFormDelegate {
    id: root

    property string label: ""
    property string description: ""
    property int from: 0
    property int to: 1000000
    /** Appended to the displayed number (e.g. "min", "days"). */
    property string unit: ""
    /** The value to show. Assign it; the row does not write back to it. */
    property int value: 0

    /** Emitted ~500 ms after the user stops changing the number, never on the initial set. */
    signal commit(int newValue)

    background: null
    Layout.fillWidth: true

    contentItem: RowLayout {
        spacing: Kirigami.Units.largeSpacing

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
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
        }

        QQC2.SpinBox {
            id: sb
            // The spin box fires valueChanged on the programmatic initial set too; only commit once
            // the user has actually moved it (ready flips after that first assignment).
            property bool ready: false
            Layout.alignment: Qt.AlignVCenter
            from: root.from
            to: root.to
            editable: true
            // ~100 steps across the range so a wide one stays navigable, snapped to 1, 2 or 5 × 10ⁿ so
            // a step lands on round numbers (0..1440 min steps by 10, not 14). GTK's spin_row matches.
            stepSize: {
                var raw = (root.to - root.from) / 100;
                if (raw <= 1) return 1;
                var mag = Math.pow(10, Math.floor(Math.log10(raw)));
                var f = raw / mag;
                return (f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10) * mag;
            }
            textFromValue: function (v, locale) { return v + (root.unit ? " " + root.unit : ""); }
            valueFromText: function (text, locale) { return parseInt(text, 10) || 0; }
            Component.onCompleted: {
                sb.value = Math.max(root.from, Math.min(root.to, root.value));
                sb.ready = true;
            }
            onValueChanged: if (sb.ready) commitTimer.restart()
            Timer {
                id: commitTimer
                interval: 500
                repeat: false
                onTriggered: root.commit(sb.value)
            }
        }
    }
}
