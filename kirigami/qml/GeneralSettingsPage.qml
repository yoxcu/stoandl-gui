import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// Daemon configuration — the curated stoandl.conf keys the daemon exposes over D-Bus
// (GetConfigSchema / GetConfig / SetConfig). Schema-driven: each key declares a type (toggle | combo)
// so new keys the daemon adds appear here automatically. Applied live (no daemon restart).
Kirigami.ScrollablePage {
    id: page
    objectName: "generalSettings"
    title: "Daemon configuration"

    property var cfgSchema: []     // [{key,type,label,options[],desc}]
    property var cfgValues: ({})   // {key:value(string)}

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    function reload() {
        if (!StoandlClient.daemonUp) { page.cfgSchema = []; page.cfgValues = ({}); return; }
        page.cfgSchema = StoandlClient.configSchema();
        var c = StoandlClient.getConfig();
        page.cfgValues = (c && c.values) ? c.values : ({});
    }

    function applyConfig(key, value) {
        var r = StoandlClient.setConfig(key, value);
        if (!r.ok) page.toast("Config: " + (r.tail || r.kind));
        page.reload();
    }

    Connections {
        target: StoandlClient
        function onDaemonUpChanged() { if (StoandlClient.daemonUp) page.reload(); }
    }

    Component.onCompleted: page.reload()

    ColumnLayout {
        spacing: 0

        DaemonPlaceholder {
            visible: !StoandlClient.daemonUp
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
        }

        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.cfgSchema.length > 0
            Layout.topMargin: Kirigami.Units.largeSpacing

            Repeater {
                model: page.cfgSchema
                delegate: Loader {
                    id: cfgLoader
                    required property var modelData
                    Layout.fillWidth: true
                    sourceComponent: modelData.type === "toggle" ? cfgToggle
                                   : modelData.type === "combo"  ? cfgCombo
                                   : cfgText

                    Component {
                        id: cfgToggle
                        FormCard.FormSwitchDelegate {
                            text: cfgLoader.modelData.label
                            description: cfgLoader.modelData.desc
                            checked: (page.cfgValues || {})[cfgLoader.modelData.key] === "true"
                            onToggled: page.applyConfig(cfgLoader.modelData.key, checked ? "true" : "false")
                        }
                    }

                    Component {
                        id: cfgCombo
                        FormCard.FormComboBoxDelegate {
                            text: cfgLoader.modelData.label
                            description: cfgLoader.modelData.desc
                            model: cfgLoader.modelData.options
                            currentIndex: { var o = cfgLoader.modelData.options || []; var i = o.indexOf((page.cfgValues || {})[cfgLoader.modelData.key]); return i >= 0 ? i : 0; }
                            onActivated: page.applyConfig(cfgLoader.modelData.key, currentValue)
                        }
                    }

                    Component {
                        id: cfgText
                        FormCard.FormTextFieldDelegate {
                            label: cfgLoader.modelData.label
                            text: (page.cfgValues || {})[cfgLoader.modelData.key] || ""
                            onEditingFinished: {
                                if (text !== ((page.cfgValues || {})[cfgLoader.modelData.key] || ""))
                                    page.applyConfig(cfgLoader.modelData.key, text);
                            }
                        }
                    }
                }
            }
        }

        Kirigami.PlaceholderMessage {
            visible: StoandlClient.daemonUp && page.cfgSchema.length === 0
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
            icon.name: "settings-configure-symbolic"
            text: "No configuration"
            explanation: "The daemon exposes no editable configuration keys."
        }

        FormCard.FormSectionText {
            visible: StoandlClient.daemonUp && page.cfgSchema.length > 0
            text: "These settings render the daemon's stoandl.conf. New keys exposed by the daemon appear here automatically, and changes apply live."
        }
    }
}
