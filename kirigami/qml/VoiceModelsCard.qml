import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import QtQuick.Dialogs as Dialogs
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// The downloadable models of one kind for Settings → Voice (VoiceModels / VoiceDownloadModel /
// VoiceRemoveModel, one store for both): speech-to-text models (`kind: "stt"`) or text-to-speech voices
// (`kind: "tts"`). It shows what is installed, a one-tap download of the recommended one while none is,
// and per-model Download, Cancel and Remove. The daemon makes a freshly downloaded model the active one
// (voice.local_model or tts.local_voice, turning its backend to Local model when it was off), so
// `changed()` asks the page to re-read its config. The voices card also plays a test sentence on this
// computer (Speak), with whichever engine tts.backend names.
ColumnLayout {
    id: card
    spacing: 0

    /** "stt" (speech models) or "tts" (voices). */
    property string kind: "stt"

    signal changed()

    property var models: []        // this kind's StoandlClient.voiceModels() rows
    property var status: ({})      // StoandlClient.voiceStatus() or ttsStatus()

    readonly property bool tts: card.kind === "tts"
    readonly property bool anyInstalled: models.some(m => m.state === "installed")
    readonly property var downloading: models.find(m => m.state === "downloading") || null
    readonly property var recommended: models.find(m => m.recommended) || null
    // Text to speech already works with some voice (espeak-ng needs no download, or a remote engine):
    // then a missing Piper and no downloaded voice are nothing to warn about.
    readonly property bool ttsReady: tts && status.kind === "ready"
    // The engine ships with its program; when the recommended model's is missing, so is the engine.
    readonly property bool engineMissing: recommended !== null && !recommended.engineOk && !ttsReady

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    function reload() {
        StoandlClient.fetch(card, [["voiceModels"], [card.tts ? "ttsStatus" : "voiceStatus"]], function (r) {
            var wasDownloading = card.downloading !== null;
            card.models = r[0].filter(function (m) { return m.kind === card.kind; });
            card.status = r[1];
            if (wasDownloading && card.downloading === null) card.changed();
        });
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

    // Plays on this computer, not the watch: the watch speaker is reached through the assistant app.
    function testVoice() {
        var r = StoandlClient.speak("This is stoandl speaking.");
        card.toast(r.ok ? "Speaking…" : r.kind === "off" ? "Text to speech is off: choose an engine above"
                                      : "Can't speak: " + (r.tail || r.kind));
        return r;
    }

    // Speech to text, tried on a recording you pick (Transcribe: a 16-bit WAV or Ogg/Opus, through
    // voice.backend; with the HTTP service the audio leaves this machine, as it would for a dictation).
    property string heard: ""
    property bool transcribing: false
    function transcribe(fileUrl) {
        var path = decodeURIComponent(String(fileUrl).replace(/^file:\/\//, ""));
        card.transcribing = true;
        card.heard = "";
        StoandlClient.run(card, ["transcribe", path], function (r) {
            card.transcribing = false;
            if (r.ok)
                card.heard = "Heard: “" + (r.fields[1] || "") + "” (" + (Number(r.fields[0]) / 1000).toFixed(1) + " s)";
            else
                card.toast(r.kind === "off" ? "Speech to text is off: choose an engine above" : "Can't transcribe: " + (r.tail || r.kind));
        });
    }

    // Smoke hook (SchemaSections runs it): the test sentence, as the button sends it, then stopped.
    function smokeExercise() {
        // A file that isn't there: the mock (speech to text off) answers off:, a real daemon off: or error:.
        StoandlClient.run(card, ["transcribe", "/nonexistent/smoke.wav"], function (t) {
            console.log("stoandl-smoke: transcribe " + t.kind);
        });
        var r = card.testVoice();
        var st = StoandlClient.stopSpeaking();
        console.log("stoandl-smoke: tts status=" + card.status.kind + " voices=" + card.models.length
                    + " speak=" + r.kind + " stop=" + st.kind);
    }

    Component.onCompleted: reload()

    // A change elsewhere (the CLI, another client, this page) can switch the engine: re-read the status.
    Connections {
        target: StoandlClient
        function onConfigChanged(key) { statusTimer.restart(); }
    }
    Timer {
        id: statusTimer
        interval: 200
        onTriggered: StoandlClient.fetch(statusTimer, [card.tts ? "ttsStatus" : "voiceStatus"], function (st) { card.status = st; })
    }

    // Progress comes from polling: one download at a time, a few minutes long, so 1 s is plenty.
    Timer {
        interval: 1000
        repeat: true
        running: card.downloading !== null
        onTriggered: card.reload()
    }

    FormCard.FormHeader { title: card.tts ? "Voices" : "Speech models" }

    Kirigami.InlineMessage {
        Layout.fillWidth: true
        Layout.leftMargin: Kirigami.Units.largeSpacing
        Layout.rightMargin: Kirigami.Units.largeSpacing
        visible: card.engineMissing
        type: Kirigami.MessageType.Warning
        text: card.tts
            ? "Piper isn't installed. Install it (sudo apk add piper-tts, from Alpine edge's testing repository), then "
              + "download a voice; or install espeak-ng (sudo apk add espeak-ng), which needs no download."
            : "The speech engine isn't installed. Install whisper.cpp (postmarketOS/Alpine: "
              + "sudo apk add whisper.cpp, Arch: whisper.cpp from the AUR), then download a model."
    }

    Kirigami.InlineMessage {
        Layout.fillWidth: true
        Layout.leftMargin: Kirigami.Units.largeSpacing
        Layout.rightMargin: Kirigami.Units.largeSpacing
        Layout.topMargin: Kirigami.Units.smallSpacing
        visible: !card.anyInstalled && !card.ttsReady && card.downloading === null && card.recommended !== null
        type: Kirigami.MessageType.Information
        text: card.recommended
            ? (card.tts ? "No voice yet. " : "No speech model yet. ") + card.recommended.name + " ("
              + card.recommended.sizeMb + " MB) is recommended: " + card.recommended.note + ". It runs on "
              + "this device; " + (card.tts ? "the text never leaves it." : "the audio never leaves it.")
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
            text: card.tts ? "Text to speech" : "Speech to text"
            description: card.status.kind === "ready" ? "Ready — " + (card.status.tail || "").split("\t").join(" ")
                       : card.status.kind === "off" ? "Off"
                       : (card.status.tail || "Not available")
            icon.name: card.tts ? (card.status.kind === "ready" ? "audio-speakers-symbolic" : "audio-volume-muted-symbolic")
                     : card.status.kind === "ready" ? "audio-input-microphone-symbolic" : "microphone-sensitivity-muted-symbolic"
            trailing: card.tts ? testButtons : sttTest

            QQC2.Button {
                id: sttTest
                visible: !card.tts
                text: card.transcribing ? "Listening…" : "Try a recording…"
                icon.name: "audio-input-microphone-symbolic"
                enabled: card.status.kind === "ready" && !card.transcribing
                onClicked: recordingDialog.open()
            }

            RowLayout {
                id: testButtons
                visible: card.tts
                spacing: Kirigami.Units.smallSpacing
                QQC2.Button {
                    text: "Test voice"
                    icon.name: "media-playback-start-symbolic"
                    enabled: card.status.kind === "ready"
                    onClicked: card.testVoice()
                }
                QQC2.ToolButton {
                    icon.name: "media-playback-stop-symbolic"
                    display: QQC2.AbstractButton.IconOnly
                    text: "Stop"
                    QQC2.ToolTip.text: text
                    QQC2.ToolTip.visible: hovered
                    onClicked: StoandlClient.stopSpeaking()
                }
            }
        }

        FormCard.FormTextDelegate {
            visible: !card.tts && card.heard !== ""
            text: card.heard
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
                            onClicked: applicationWindow().confirm(text,
                                "Remove " + row.modelData.name + "? Using it again means downloading its "
                                + row.modelData.sizeMb + " MB again.", "Remove", "edit-delete-symbolic",
                                function () { card.remove(row.modelData.id); })
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
        text: card.tts
            ? "Voices are saved under ~/.local/share/stoandl/tts. A download is the only time stoandl contacts "
              + "huggingface.co for them; speech is made on this device. Test voice plays here; answers play on "
              + "the watch speaker through the assistant app."
            : "Models are saved under ~/.local/share/stoandl/stt. A download is the only time stoandl contacts "
              + "huggingface.co for voice; recognition runs on this device."
    }

    Dialogs.FileDialog {
        id: recordingDialog
        title: "Try speech to text on a recording"
        nameFilters: ["Recordings (*.wav *.ogg *.opus)", "All files (*)"]
        onAccepted: card.transcribe(selectedFile)
    }
}
