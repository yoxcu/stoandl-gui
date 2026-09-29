import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard

/*
 * A text-entry row for a FormCard — our stand-in for FormCard.FormTextFieldDelegate.
 *
 * We don't use FormTextFieldDelegate because it calls `i18ndc()` for its character-counter label, and
 * this app deliberately links no KF6 C++ (no KLocalizedContext on the engine), so that throws
 * `ReferenceError: i18ndc is not defined` at runtime on every instance. The counter is invisible anyway
 * — the binding is evaluated regardless of its `visible` — so the errors were pure noise that could mask
 * a real one. Same reason FormColorDelegate is avoided (see CLAUDE.md).
 *
 * It also gains a `description` line, which FormTextFieldDelegate has no property for at all.
 *
 * API differs from FormTextFieldDelegate in ONE way: the text is `value`, not `text` — AbstractFormDelegate
 * derives from T.ItemDelegate, which already owns `text`. So `onTextChanged` becomes `onValueChanged`.
 */
FormCard.AbstractFormDelegate {
    id: root

    /** Field label, shown above the entry. */
    property string label: ""
    /** Optional smaller explanatory line under the label. */
    property string description: ""
    /** Validation message under the entry, in the negative colour; empty = valid (hidden). */
    property string error: ""
    /** The edited text. Named `value` to avoid ItemDelegate's own `text`. */
    property alias value: field.text
    property alias placeholderText: field.placeholderText
    property alias echoMode: field.echoMode
    property alias inputMethodHints: field.inputMethodHints
    /** The inner TextField, for focus handling. */
    property alias field: field

    signal editingFinished()

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

        QQC2.TextField {
            id: field
            Layout.fillWidth: true
            onEditingFinished: root.editingFinished()
        }

        QQC2.Label {
            Layout.fillWidth: true
            visible: root.error !== ""
            text: root.error
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            color: Kirigami.Theme.negativeTextColor
        }
    }
}
