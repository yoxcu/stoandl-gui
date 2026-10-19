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
 * auto-repeat, and both callers respond to a commit with a D-Bus write and a re-read. So `commit` is
 * emitted once, ~500 ms after the user stops — never per tick.
 *
 * The row outlives a commit (the callers patch values into stable rows), so it follows `value`: a
 * re-read that changes it moves the spin box, except while the user's own edit is still pending (that
 * edit wins and is committed). Right after a commit it shows `value` again, which is the daemon's
 * stored number by then, so a refused or normalised value doesn't linger.
 */
FormCard.AbstractFormDelegate {
    id: root

    property string label: ""
    property string description: ""
    /** Longer text behind the (?) button next to the label; empty = no button. */
    property string help: ""
    property int from: 0
    property int to: 1000000
    /** One arrow press, key press or wheel tick. By default ~100 steps across the range so a wide one
     *  stays navigable, snapped to 1, 2 or 5 × 10ⁿ so a step lands on round numbers (0..1440 min steps
     *  by 10, not 14); a row whose range is only a sanity bound sets 1. */
    property int stepSize: {
        var raw = (root.to - root.from) / 100;
        if (raw <= 1) return 1;
        var mag = Math.pow(10, Math.floor(Math.log10(raw)));
        var f = raw / mag;
        return (f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10) * mag;
    }
    /** The value can't be changed now (a setting it depends on is off); the help still opens.
     *  (`enabled: false` would disable the (?) with it.) */
    property bool locked: false
    /** Appended to the displayed number (e.g. "min", "days"). */
    property string unit: ""
    /** The value to show. Bind it; the row does not write back to it. */
    property int value: 0
    /** What the spin box shows now, the user's pending edit included (a form that saves all its fields at
     *  once reads this instead of waiting for commit). */
    readonly property int shownValue: sb.value

    onValueChanged: if (!commitTimer.running) sb.show(root.value)
    onFromChanged: if (!commitTimer.running) sb.show(root.value)
    onToChanged: if (!commitTimer.running) sb.show(root.value)

    /** Emitted ~500 ms after the user stops changing the number, never on the initial set. */
    signal commit(int newValue)

    background: null
    Layout.fillWidth: true
    Accessible.description: root.description + (root.help !== "" ? " " + root.help : "")
    Keys.onPressed: (event) => helpButton.keyPressed(event)

    TapHandler {
        acceptedButtons: Qt.RightButton
        onTapped: helpButton.show()
    }

    contentItem: RowLayout {
        spacing: Kirigami.Units.largeSpacing

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            RowLayout {
                Layout.fillWidth: true
                visible: root.label !== ""
                spacing: Kirigami.Units.smallSpacing

                QQC2.Label {
                    Layout.fillWidth: true
                    text: root.label
                    elide: Text.ElideRight
                    color: root.enabled && !root.locked ? Kirigami.Theme.textColor : Kirigami.Theme.disabledTextColor

                    // A long press on the label opens the help (the field and the buttons own the rest of the row).
                    TapHandler {
                        onLongPressed: helpButton.holdStarted()
                        onPressedChanged: if (!pressed) helpButton.holdEnded()
                    }
                }

                RowHelp {
                    id: helpButton
                    help: root.help
                }
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
            enabled: !root.locked
            from: root.from
            to: root.to
            editable: true
            stepSize: root.stepSize
            textFromValue: function (v, locale) { return v + (root.unit ? " " + root.unit : ""); }
            valueFromText: function (text, locale) { return parseInt(text, 10) || 0; }
            // A programmatic set (the initial value, a re-read) that must not look like an edit.
            function show(v) {
                sb.ready = false;
                sb.value = Math.max(root.from, Math.min(root.to, v));
                sb.ready = true;
            }
            Component.onCompleted: sb.show(root.value)
            onValueChanged: if (sb.ready) commitTimer.restart()
            Timer {
                id: commitTimer
                interval: 500
                repeat: false
                onTriggered: {
                    root.commit(sb.value);
                    sb.show(root.value);
                }
            }
        }
    }
}
