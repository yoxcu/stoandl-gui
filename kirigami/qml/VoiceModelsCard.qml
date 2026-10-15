import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// The speech models for Settings → Voice (VoiceModels / VoiceDownloadModel / VoiceRemoveModel): what is
// installed, a one-tap download of the recommended model while none is, and per-model Download, Cancel
// and Remove. The daemon makes a freshly downloaded model the active one when voice was off or local, so
// `changed()` asks the page to re-read its config (the schema's "Model" dropdown lists installed models).
ColumnLayout {
    id: card
    spacing: 0

    signal changed()

    property var models: []        // StoandlClient.voiceModels()
    property var status: ({})      // StoandlClient.voiceStatus()

    readonly property bool anyInstalled: models.some(m => m.state === "installed")
    readonly property var downloading: models.find(m => m.state === "downloading") || null
    readonly property var recommended: models.find(m => m.recommended) || null
    // whisper.cpp ships both programs; when the recommended one is missing, so is the engine.
    readonly property bool engineMissing: recommended !== null && !recommended.engineOk

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    function reload() {
        var wasDownloading = card.downloading !== null;
        card.models = StoandlClient.voiceModels();
        card.status = StoandlClient.voiceStatus();
        if (wasDownloading && card.downloading === null) card.changed();
    }

    function download(id) {
        var r = StoandlClient.voiceDownloadModel(id);
        if (!r.ok && r.kind !== "installed") card.toast(r.tail || r.kind);
        card.reload();
        if (r.kind === "installed") card.changed();
    }

    function remove(id) {
        var r = StoandlClient.voiceRemoveModel(id);
        if (!r.ok) card.toast(r.tail || r.kind);
        card.reload();
        card.changed();
    }

    Component.onCompleted: reload()

    // Progress comes from polling: one download at a time, a few minutes long, so 1 s is plenty.
    Timer {
        interval: 1000
        repeat: true
        running: card.downloading !== null
        onTriggered: card.reload()
    }

    FormCard.FormHeader { title: "Speech models" }

    Kirigami.InlineMessage {
        Layout.fillWidth: true
        Layout.leftMargin: Kirigami.Units.largeSpacing
        Layout.rightMargin: Kirigami.Units.largeSpacing
        visible: card.engineMissing
        type: Kirigami.MessageType.Warning
        text: "The speech engine isn't installed. Install whisper.cpp (postmarketOS/Alpine: "
            + "sudo apk add whisper.cpp, Arch: whisper.cpp from the AUR), then download a model."
    }

    Kirigami.InlineMessage {
        Layout.fillWidth: true
        Layout.leftMargin: Kirigami.Units.largeSpacing
        Layout.rightMargin: Kirigami.Units.largeSpacing
        Layout.topMargin: Kirigami.Units.smallSpacing
        visible: !card.anyInstalled && card.downloading === null && card.recommended !== null
        type: Kirigami.MessageType.Information
        text: card.recommended
            ? "No speech model yet. " + card.recommended.name + " (" + card.recommended.sizeMb
              + " MB) is recommended: " + card.recommended.note + ". It runs on this device; the audio never leaves it."
            : ""
        actions: [
            Kirigami.Action {
                text: card.recommended ? "Download " + card.recommended.name : ""
                icon.name: "download-symbolic"
                onTriggered: card.download(card.recommended.id)
            }
        ]
    }

    FormCard.FormCard {
        Layout.topMargin: Kirigami.Units.smallSpacing

        FormCard.FormTextDelegate {
            text: "Voice"
            description: card.status.kind === "ready" ? "Ready — " + (card.status.tail || "").split("\t").join(" ")
                       : card.status.kind === "off" ? "Off"
                       : (card.status.tail || "Not available")
            icon.name: card.status.kind === "ready" ? "audio-input-microphone-symbolic" : "microphone-sensitivity-muted-symbolic"
        }

        Repeater {
            model: card.models
            delegate: FormCard.AbstractFormDelegate {
                id: row
                required property var modelData
                background: null
                hoverEnabled: false
                Accessible.name: modelData.name

                contentItem: ColumnLayout {
                    spacing: Kirigami.Units.smallSpacing

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.largeSpacing

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: row.modelData.name + (row.modelData.recommended ? "  · recommended" : "")
                                elide: Text.ElideRight
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: row.modelData.sizeMb + " MB · " + row.modelData.note
                                    + (row.modelData.state === "failed" ? "\nDownload failed: " + row.modelData.error : "")
                                font: Kirigami.Theme.smallFont
                                color: row.modelData.state === "failed" ? Kirigami.Theme.negativeTextColor
                                                                       : Kirigami.Theme.disabledTextColor
                                wrapMode: Text.Wrap
                            }
                        }

                        QQC2.Label {
                            visible: row.modelData.state === "installed"
                            text: "Installed"
                            color: Kirigami.Theme.positiveTextColor
                        }
                        QQC2.Button {
                            visible: row.modelData.state === "available" || row.modelData.state === "failed"
                            enabled: card.downloading === null
                            text: row.modelData.state === "failed" ? "Retry" : "Download"
                            icon.name: "download-symbolic"
                            onClicked: card.download(row.modelData.id)
                        }
                        QQC2.Label {
                            visible: row.modelData.state === "downloading"
                            text: row.modelData.progress + " %"
                        }
                        QQC2.Button {
                            visible: row.modelData.state === "downloading"
                            text: "Cancel"
                            icon.name: "dialog-cancel-symbolic"
                            onClicked: { StoandlClient.voiceCancelDownload(); card.reload(); }
                        }
                        QQC2.ToolButton {
                            visible: row.modelData.state === "installed"
                            icon.name: "edit-delete-symbolic"
                            display: QQC2.AbstractButton.IconOnly
                            text: "Remove " + row.modelData.name
                            QQC2.ToolTip.text: text
                            QQC2.ToolTip.visible: hovered
                            onClicked: card.remove(row.modelData.id)
                        }
                    }

                    QQC2.ProgressBar {
                        Layout.fillWidth: true
                        visible: row.modelData.state === "downloading"
                        from: 0
                        to: 100
                        value: row.modelData.progress
                    }
                }
            }
        }
    }

    FormCard.FormSectionText {
        text: "Models are saved under ~/.local/share/stoandl/stt. A download is the only time stoandl contacts "
            + "huggingface.co for voice; recognition runs on this device."
    }
}
