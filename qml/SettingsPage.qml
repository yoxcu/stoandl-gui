import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import QtQuick.Dialogs as Dialogs
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

Kirigami.ScrollablePage {
    id: page
    objectName: "settings"
    title: "Settings"

    // Latest snapshots (all parsed in C++).
    property var syncStatus: []      // [{service,enabled,available,lastSync}]
    property var calendars: []       // [{id,name,enabled}]
    property var watchPrefs: []      // [{id,type,current,currentBool,currentInt,default,allowed[],flags[],name,description}]
    property var cfgSchema: []       // [{key,type,label,options[],desc}]
    property var cfgValues: ({})     // {key:value(string)}

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    // notifications live on the Notifications screen — never shown here.
    readonly property var syncServices: page.syncStatus.filter(function (s) { return s.service !== "notifications"; })

    function serviceLabel(service) {
        if (service === "weather")  return "Weather";
        if (service === "calendar") return "Calendar";
        if (service === "music")    return "Music";
        if (service === "health")   return "Health";
        if (service === "dnd")      return "Do Not Disturb";
        return service;
    }

    // --- loaders -----------------------------------------------------------
    function reload() {
        if (!StoandlClient.daemonUp) {
            page.syncStatus = [];
            page.calendars = [];
            page.watchPrefs = [];
            page.cfgSchema = [];
            page.cfgValues = ({});
            return;
        }
        page.reloadSync();
        page.reloadPrefs();
        page.reloadConfig();
        StoandlClient.refreshCalendars();
    }

    function reloadSync()   { page.syncStatus = StoandlClient.getSyncStatus(); }
    function reloadPrefs()  { page.watchPrefs = StoandlClient.listWatchPrefs(); }
    function reloadConfig() {
        page.cfgSchema = StoandlClient.configSchema();
        var c = StoandlClient.getConfig();
        page.cfgValues = (c && c.values) ? c.values : ({});
    }

    // --- mutations ---------------------------------------------------------
    function toggleSync(service, on) {
        var r = StoandlClient.setSyncEnabled(service, on);
        if (!r.ok)
            page.toast(page.serviceLabel(service) + ": " + (r.tail || r.kind));
        page.reloadSync();
    }

    function forceSync(fn, label) {
        var r = fn();
        if (r.ok) page.toast(label + " synced");
        else      page.toast(label + ": " + (r.tail !== "" ? r.tail : r.kind));
        page.reloadSync();   // a force-sync updates the service's lastSync label
    }

    function syncAll() {
        page.forceSync(StoandlClient.syncWeather, "Weather");
        page.forceSync(StoandlClient.syncCalendar, "Calendar");
        page.forceSync(StoandlClient.syncHealth, "Health");
    }

    function toggleCalendar(id, on) {
        var r = StoandlClient.setCalendarEnabled(id, on);
        if (!r.ok)
            page.toast("Calendar: " + (r.tail || r.kind));
        StoandlClient.refreshCalendars();
    }

    function applyPref(id, value) {
        var r = StoandlClient.setWatchPref(id, value);
        if (!r.ok)
            page.toast("Setting: " + (r.tail || r.kind));
        page.reloadPrefs();
    }

    function applyConfig(key, value) {
        var r = StoandlClient.setConfig(key, value);
        if (!r.ok)
            page.toast("Config: " + (r.tail || r.kind));
        page.reloadConfig();
    }

    // Parse an int range like "0..400" -> {from, to}; safe fallback otherwise.
    function parseRange(allowed) {
        if (allowed && allowed.length > 0) {
            var parts = String(allowed[0]).split("..");
            if (parts.length === 2) {
                var lo = parseInt(parts[0], 10);
                var hi = parseInt(parts[1], 10);
                if (!isNaN(lo) && !isNaN(hi))
                    return { from: lo, to: hi };
            }
        }
        return { from: 0, to: 100 };
    }

    Connections {
        target: StoandlClient
        function onCalendarsChanged(rows) { page.calendars = rows; }
        function onCliResult(op, ok, message) {
            if (op === "backup")
                page.toast(ok ? "Backup complete" : ("Backup failed: " + message));
            else if (op === "restore")
                page.toast(ok ? "Restore complete" : ("Restore failed: " + message));
            else if (op === "support")
                page.toast(ok ? "Support bundle created" : ("Support bundle failed: " + message));
        }
        function onDaemonUpChanged() {
            if (StoandlClient.daemonUp) page.reload();
        }
    }

    Component.onCompleted: page.reload()

    actions: [
        Kirigami.Action {
            icon.name: "view-refresh-symbolic"
            text: "Sync all now"
            enabled: StoandlClient.daemonUp
            onTriggered: { page.syncAll(); page.reloadSync(); }
        }
    ]

    ColumnLayout {
        spacing: 0

        // --- daemon-not-running state --------------------------------------
        DaemonPlaceholder {
            visible: !StoandlClient.daemonUp
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
        }

        // ============ SYNC SERVICES ============
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp
            title: "Sync services"
        }

        FormCard.FormCard {
            visible: StoandlClient.daemonUp

            Repeater {
                model: page.syncServices
                delegate: FormCard.FormSwitchDelegate {
                    required property var modelData
                    text: page.serviceLabel(modelData.service)
                    description: "Last sync · " + (modelData.lastSync || "never")
                    enabled: modelData.available !== false
                    checked: modelData.enabled === true
                    onToggled: page.toggleSync(modelData.service, checked)
                }
            }
        }

        // --- Sync now (force-sync) -----------------------------------------
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp
            title: "Sync now"
        }

        FormCard.FormCard {
            visible: StoandlClient.daemonUp

            FormCard.FormButtonDelegate {
                text: "Weather"
                icon.name: "weather-clear-symbolic"
                onClicked: page.forceSync(StoandlClient.syncWeather, "Weather")
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormButtonDelegate {
                text: "Calendar"
                icon.name: "view-calendar-symbolic"
                onClicked: page.forceSync(StoandlClient.syncCalendar, "Calendar")
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormButtonDelegate {
                text: "Health"
                icon.name: "favorite-symbolic"
                onClicked: page.forceSync(StoandlClient.syncHealth, "Health")
            }
        }

        // --- Calendars ------------------------------------------------------
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp && page.calendars.length > 0
            title: "Calendars"
        }

        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.calendars.length > 0

            Repeater {
                model: page.calendars
                delegate: FormCard.FormSwitchDelegate {
                    required property var modelData
                    text: modelData.name
                    checked: modelData.enabled === true
                    onToggled: page.toggleCalendar(modelData.id, checked)
                }
            }
        }

        // ============ WATCH SETTINGS ============
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp && page.watchPrefs.length > 0
            title: "Watch settings"
        }

        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.watchPrefs.length > 0

            Repeater {
                model: page.watchPrefs
                delegate: Loader {
                    required property var modelData
                    Layout.fillWidth: true
                    sourceComponent: modelData.type === "bool" ? boolPref
                                   : modelData.type === "enum" ? enumPref
                                   : intPref

                    Component {
                        id: boolPref
                        FormCard.FormSwitchDelegate {
                            text: modelData.name
                            description: modelData.description
                            checked: modelData.currentBool === true
                            onToggled: page.applyPref(modelData.id, checked ? "true" : "false")
                        }
                    }

                    Component {
                        id: enumPref
                        FormCard.FormComboBoxDelegate {
                            text: modelData.name
                            description: modelData.description
                            model: modelData.allowed
                            // currentValue is read-only (alias to ComboBox.currentValue); drive the
                            // shown selection via currentIndex. onActivated reads back the picked string.
                            currentIndex: { var o = modelData.allowed || []; var i = o.indexOf(modelData.current); return i >= 0 ? i : 0; }
                            onActivated: page.applyPref(modelData.id, currentValue)
                        }
                    }

                    Component {
                        id: intPref
                        FormCard.AbstractFormDelegate {
                            id: intRow
                            readonly property var range: page.parseRange(modelData.allowed)
                            background: null

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
                                            text: modelData.name
                                            elide: Text.ElideRight
                                        }
                                        QQC2.Label {
                                            Layout.fillWidth: true
                                            visible: modelData.description !== ""
                                            text: modelData.description
                                            elide: Text.ElideRight
                                            font: Kirigami.Theme.smallFont
                                            opacity: 0.7
                                        }
                                    }
                                    QQC2.Label {
                                        text: prefSlider.value
                                        color: Kirigami.Theme.highlightColor
                                        font.bold: true
                                    }
                                }

                                QQC2.Slider {
                                    id: prefSlider
                                    Layout.fillWidth: true
                                    from: intRow.range.from
                                    to: intRow.range.to
                                    stepSize: 1
                                    snapMode: QQC2.Slider.SnapAlways
                                    value: modelData.currentInt
                                    onMoved: page.applyPref(modelData.id, String(Math.round(value)))
                                }
                            }
                        }
                    }
                }
            }
        }

        // ============ BACKUP ============
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp
            title: "Backup"
        }

        FormCard.FormCard {
            visible: StoandlClient.daemonUp

            FormCard.FormButtonDelegate {
                text: "Back up now"
                description: "Save a full backup of the watch and daemon state"
                icon.name: "document-save-symbolic"
                onClicked: { StoandlClient.backup(""); page.toast("Backing up…"); }
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormButtonDelegate {
                text: "Restore from file…"
                description: "Restore a previously saved backup"
                icon.name: "document-open-symbolic"
                onClicked: restoreDialog.open()
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormButtonDelegate {
                text: "Create support bundle"
                description: "Collect logs and diagnostics for a bug report"
                icon.name: "help-feedback-symbolic"
                onClicked: { StoandlClient.supportBundle(""); page.toast("Building support bundle…"); }
            }
        }

        // ============ ADVANCED ============
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp && page.cfgSchema.length > 0
            title: "Advanced"
        }

        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.cfgSchema.length > 0

            Repeater {
                model: page.cfgSchema
                delegate: Loader {
                    required property var modelData
                    Layout.fillWidth: true
                    sourceComponent: modelData.type === "toggle" ? cfgToggle
                                   : modelData.type === "combo"  ? cfgCombo
                                   : cfgText

                    Component {
                        id: cfgToggle
                        FormCard.FormSwitchDelegate {
                            text: modelData.label
                            description: modelData.desc
                            checked: (page.cfgValues || {})[modelData.key] === "true"
                            onToggled: page.applyConfig(modelData.key, checked ? "true" : "false")
                        }
                    }

                    Component {
                        id: cfgCombo
                        FormCard.FormComboBoxDelegate {
                            text: modelData.label
                            description: modelData.desc
                            model: modelData.options
                            // currentValue is read-only; drive the selection via currentIndex.
                            currentIndex: { var o = modelData.options || []; var i = o.indexOf((page.cfgValues || {})[modelData.key]); return i >= 0 ? i : 0; }
                            onActivated: page.applyConfig(modelData.key, currentValue)
                        }
                    }

                    Component {
                        id: cfgText
                        FormCard.FormTextFieldDelegate {
                            label: modelData.label
                            text: (page.cfgValues || {})[modelData.key] || ""
                            onEditingFinished: {
                                if (text !== ((page.cfgValues || {})[modelData.key] || ""))
                                    page.applyConfig(modelData.key, text);
                            }
                        }
                    }
                }
            }
        }

        // Schema-driven note: new stoandl.conf keys appear here automatically.
        QQC2.Label {
            visible: StoandlClient.daemonUp && page.cfgSchema.length > 0
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.largeSpacing
            text: "These settings render the daemon's stoandl.conf. New keys exposed by the daemon appear here automatically."
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            opacity: 0.7
        }
    }

    // --- restore file picker (absolute daemon-side path) -------------------
    Dialogs.FileDialog {
        id: restoreDialog
        title: "Restore from backup"
        nameFilters: ["Backup archives (*.tar *.tar.gz *.tgz *.zip)", "All files (*)"]
        onAccepted: {
            StoandlClient.restore(selectedFile);
            page.toast("Restoring…");
        }
    }
}
