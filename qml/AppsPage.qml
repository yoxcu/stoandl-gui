import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import QtQuick.Dialogs as Dialogs
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

Kirigami.ScrollablePage {
    id: page
    objectName: "apps"
    title: "Apps & Faces"

    // Which segment is showing: "faces" | "apps" | "ext".
    property string segment: "faces"

    // Latest ListApps snapshot (parsed + flag-decoded in C++), split by isFace.
    property var apps: []
    readonly property var faces: apps.filter(function (a) { return a.isFace; })
    readonly property var others: apps.filter(function (a) { return !a.isFace; })

    // Latest ExtList snapshot.
    property var extensions: []

    readonly property bool extSegment: segment === "ext"

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    function reload() {
        StoandlClient.refreshApps();
        StoandlClient.refreshExtensions();
    }

    // --- Faces / Apps actions ---------------------------------------------
    function doLaunch(app) {
        var r = StoandlClient.launchApp(app.uuid);
        if (!r.ok)
            page.toast("Launch failed: " + (r.tail || r.kind));
        else
            page.toast("Launched " + app.title);
        StoandlClient.refreshApps(); // launching a face changes the active flag
    }

    function doRemove(app) {
        var r = StoandlClient.removeApp(app.uuid);
        if (!r.ok)
            page.toast("Remove failed: " + (r.tail || r.kind));
        StoandlClient.refreshApps(); // re-fetch after mutation
    }

    function doConfig(app) {
        var r = StoandlClient.openConfig(app.uuid);
        if (r.kind === "ok" && r.opened)
            page.toast("Opening config in your browser…");
        else if (r.kind === "none")
            page.toast("No config available — is the app running on the watch?");
        else
            page.toast("Config unavailable: " + (r.msg || r.kind));
    }

    // --- Extension actions -------------------------------------------------
    function extToggle(extData) {
        var r = extData.enabled ? StoandlClient.extDisable(extData.name)
                                : StoandlClient.extEnable(extData.name);
        if (r.kind !== "ok")
            page.toast((extData.enabled ? "Disable" : "Enable") + " failed: " + (r.tail || r.kind));
        StoandlClient.refreshExtensions(); // re-fetch after mutation
    }

    function configureExt(extData) {
        if (extData.config === "url") {
            var r = StoandlClient.extOpenConfig(extData.name);
            if (r.kind === "ok" && r.opened)
                page.toast("Opening " + extData.name + " settings…");
            else
                page.toast("Settings unavailable: " + (r.msg || r.kind));
        } else if (extData.config === "schema") {
            extConfigDialog.openFor(extData.name);
        } else {
            page.toast("No settings for " + extData.name);
        }
    }

    Connections {
        target: StoandlClient
        function onAppsChanged(rows) { page.apps = rows; }
        function onExtensionsChanged(rows) { page.extensions = rows; }
        function onDaemonUpChanged() {
            if (StoandlClient.daemonUp)
                page.reload();
        }
    }

    // Re-fetch on show + after every mutation (no LockerChanged signal yet).
    Component.onCompleted: page.reload()

    // Segment-aware primary action (§4-0): install .pbw for faces/apps,
    // install an archive for extensions.
    actions: [
        Kirigami.Action {
            icon.name: "list-add"
            text: page.extSegment ? "Install extension" : "Install .pbw"
            enabled: StoandlClient.daemonUp
            onTriggered: page.extSegment ? extFileDialog.open() : pbwFileDialog.open()
        },
        Kirigami.Action {
            icon.name: "view-refresh-symbolic"
            // Re-reads the locker from the daemon (ListApps) — the watch↔locker sync is automatic, so
            // this only refreshes what's shown here, hence "Refresh" rather than "Sync".
            text: "Refresh"
            enabled: StoandlClient.daemonUp
            onTriggered: { page.reload(); page.toast("Refreshed"); }
        }
    ]

    // --- One reusable row for both the Faces and Apps segments -------------
    component AppRow: FormCard.AbstractFormDelegate {
        id: row
        required property var appData

        // The app's extracted menu-icon PNG (file:// URL), fetched lazily from the daemon's local
        // cache. Empty until resolved or when the daemon has no icon — then we show a generic glyph.
        property string iconUrl: ""
        Component.onCompleted: row.iconUrl = StoandlClient.appIcon(row.appData.uuid)

        onClicked: page.doLaunch(appData)

        contentItem: RowLayout {
            spacing: Kirigami.Units.largeSpacing

            // Extracted menu icon when available, otherwise a themed generic glyph. Menu icons are tiny
            // bitmaps (~25 px); don't force-upscale them to fill the slot — a non-integer nearest-neighbour
            // stretch mangles 1 px detail. Render at native size, centered; smoothing only matters for the
            // DPR/downscale path.
            Item {
                implicitWidth: Kirigami.Units.iconSizes.medium
                implicitHeight: Kirigami.Units.iconSizes.medium

                Image {
                    id: menuIcon
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, parent.width)
                    height: Math.min(implicitHeight, parent.height)
                    source: row.iconUrl
                    visible: row.iconUrl !== "" && status === Image.Ready
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    mipmap: true
                    asynchronous: true
                    cache: true
                }

                Kirigami.Icon {
                    anchors.fill: parent
                    visible: !menuIcon.visible
                    source: row.appData.active ? "starred-symbolic"
                           : row.appData.isFace ? "preferences-desktop-theme-symbolic"
                           : "application-x-executable-symbolic"
                    color: row.appData.active ? Kirigami.Theme.highlightColor
                                              : Kirigami.Theme.textColor
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                QQC2.Label {
                    Layout.fillWidth: true
                    text: row.appData.title
                    elide: Text.ElideRight
                }
                QQC2.Label {
                    Layout.fillWidth: true
                    text: row.appData.developer !== "" ? row.appData.developer : row.appData.uuid
                    elide: Text.ElideRight
                    font: Kirigami.Theme.smallFont
                    opacity: 0.7
                }
            }

            // "active" chip on the running face/app.
            StatusChip {
                visible: row.appData.active === true
                label: "active"
                tint: Kirigami.Theme.positiveTextColor
            }

            // Open the app's config webview (config-capable apps only).
            QQC2.ToolButton {
                visible: row.appData.config === true
                icon.name: "configure-symbolic"
                display: QQC2.AbstractButton.IconOnly
                QQC2.ToolTip.text: "Settings"
                QQC2.ToolTip.visible: hovered
                onClicked: page.doConfig(row.appData) // consumes click -> no row launch
            }

            // Remove from locker (system apps can't be removed).
            QQC2.ToolButton {
                visible: row.appData.system !== true
                icon.name: "edit-delete-symbolic"
                display: QQC2.AbstractButton.IconOnly
                QQC2.ToolTip.text: "Delete from locker"
                QQC2.ToolTip.visible: hovered
                onClicked: removeConfirm.openFor(row.appData)
            }
        }
    }

    ColumnLayout {
        spacing: 0

        // --- daemon-not-running state --------------------------------------
        DaemonPlaceholder {
            visible: !StoandlClient.daemonUp
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
        }

        // --- segmented control (Faces / Apps / Extensions) -----------------
        FormCard.FormCard {
            visible: StoandlClient.daemonUp
            Layout.topMargin: Kirigami.Units.largeSpacing

            QQC2.Pane {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.largeSpacing
                padding: Kirigami.Units.smallSpacing
                background: null

                contentItem: RowLayout {
                    spacing: Kirigami.Units.smallSpacing

                    QQC2.Button {
                        Layout.fillWidth: true
                        text: "Faces · " + page.faces.length
                        checkable: true
                        autoExclusive: true
                        checked: page.segment === "faces"
                        onClicked: page.segment = "faces"
                    }
                    QQC2.Button {
                        Layout.fillWidth: true
                        text: "Apps · " + page.others.length
                        checkable: true
                        autoExclusive: true
                        checked: page.segment === "apps"
                        onClicked: page.segment = "apps"
                    }
                    QQC2.Button {
                        Layout.fillWidth: true
                        text: "Extensions · " + page.extensions.length
                        checkable: true
                        autoExclusive: true
                        checked: page.segment === "ext"
                        onClicked: page.segment = "ext"
                    }
                }
            }
        }

        // --- Faces / Apps empty state --------------------------------------
        Kirigami.PlaceholderMessage {
            visible: StoandlClient.daemonUp && page.segment === "faces" && page.faces.length === 0
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
            icon.name: "preferences-desktop-theme-symbolic"
            text: "No watchfaces"
            explanation: "Install a .pbw to get started."
            helpfulAction: Kirigami.Action {
                icon.name: "list-add"
                text: "Install .pbw"
                onTriggered: pbwFileDialog.open()
            }
        }

        Kirigami.PlaceholderMessage {
            visible: StoandlClient.daemonUp && page.segment === "apps" && page.others.length === 0
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
            icon.name: "application-x-executable-symbolic"
            text: "No apps"
            explanation: "Install a .pbw to get started."
            helpfulAction: Kirigami.Action {
                icon.name: "list-add"
                text: "Install .pbw"
                onTriggered: pbwFileDialog.open()
            }
        }

        Kirigami.PlaceholderMessage {
            visible: StoandlClient.daemonUp && page.extSegment && page.extensions.length === 0
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
            icon.name: "preferences-plugin-symbolic"
            text: "No extensions installed"
            explanation: "Extensions are host-side companions that drive watch notifications with quick replies and actions."
            helpfulAction: Kirigami.Action {
                icon.name: "list-add"
                text: "Install extension"
                onTriggered: extFileDialog.open()
            }
        }

        // --- Faces list ----------------------------------------------------
        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.segment === "faces" && page.faces.length > 0
            Layout.topMargin: Kirigami.Units.largeSpacing

            Repeater {
                model: page.faces
                delegate: AppRow {
                    required property var modelData
                    appData: modelData
                }
            }
        }

        // --- Apps list -----------------------------------------------------
        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.segment === "apps" && page.others.length > 0
            Layout.topMargin: Kirigami.Units.largeSpacing

            Repeater {
                model: page.others
                delegate: AppRow {
                    required property var modelData
                    appData: modelData
                }
            }
        }

        // --- Extensions list -----------------------------------------------
        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.extSegment && page.extensions.length > 0
            Layout.topMargin: Kirigami.Units.largeSpacing

            Repeater {
                model: page.extensions

                delegate: FormCard.FormSwitchDelegate {
                    id: extRow
                    required property var modelData

                    text: modelData.name
                    description: modelData.description
                    checked: modelData.enabled === true
                    onToggled: page.extToggle(modelData)

                    trailing: RowLayout {
                        spacing: Kirigami.Units.smallSpacing

                        // Runtime-state chip from ExtensionStateChanged: a quarantined or crashed
                        // (exited, restarting) extension is shown distinctly instead of the stale
                        // polled "running". Hidden for the normal running/stopped states.
                        StatusChip {
                            readonly property string rs: extRow.modelData.runtimeState || ""
                            visible: rs === "quarantined" || rs === "exited"
                            label: rs === "quarantined" ? "Quarantined" : "Crashed (restarting)"
                            tint: rs === "quarantined" ? Kirigami.Theme.negativeTextColor
                                                       : Kirigami.Theme.neutralTextColor
                        }

                        QQC2.ToolButton {
                            visible: extRow.modelData.hasConfig === true
                            icon.name: "configure-symbolic"
                            display: QQC2.AbstractButton.IconOnly
                            QQC2.ToolTip.text: "Settings"
                            QQC2.ToolTip.visible: hovered
                            onClicked: page.configureExt(extRow.modelData)
                        }

                        QQC2.ToolButton {
                            icon.name: "edit-delete-symbolic"
                            display: QQC2.AbstractButton.IconOnly
                            QQC2.ToolTip.text: "Uninstall"
                            QQC2.ToolTip.visible: hovered
                            onClicked: uninstallConfirm.openFor(extRow.modelData.name)
                        }
                    }
                }
            }
        }

        // Footnote echoing the prototype's host-side companion explainer.
        FormCard.FormTextDelegate {
            visible: StoandlClient.daemonUp && page.extSegment && page.extensions.length > 0
            text: "Extensions are host-side companions that drive watch notifications with quick replies and actions."
        }
    }

    // --- remove app/face confirmation --------------------------------------
    Kirigami.PromptDialog {
        id: removeConfirm
        title: "Delete from locker"
        standardButtons: QQC2.Dialog.NoButton

        property var appData: ({})

        function openFor(app) {
            appData = app;
            subtitle = "Remove \"" + (app.title || app.uuid) + "\" from the locker? You can install it again later.";
            open();
        }

        customFooterActions: [
            Kirigami.Action {
                text: "Delete"
                icon.name: "edit-delete-symbolic"
                onTriggered: {
                    page.doRemove(removeConfirm.appData);
                    removeConfirm.close();
                }
            },
            Kirigami.Action {
                text: "Cancel"
                icon.name: "dialog-cancel-symbolic"
                onTriggered: removeConfirm.close()
            }
        ]
    }

    // --- extension uninstall confirmation (keep-config option) -------------
    Kirigami.PromptDialog {
        id: uninstallConfirm
        title: "Uninstall extension"
        standardButtons: QQC2.Dialog.NoButton

        property string extName: ""

        function openFor(name) {
            extName = name;
            keepConfigBox.checked = true;
            open();
        }

        ColumnLayout {
            spacing: Kirigami.Units.largeSpacing
            QQC2.Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: "Stops " + uninstallConfirm.extName + " and removes its files."
            }
            QQC2.CheckBox {
                id: keepConfigBox
                text: "Keep configuration so you can reinstall later"
                checked: true
            }
        }

        customFooterActions: [
            Kirigami.Action {
                text: "Uninstall"
                icon.name: "edit-delete-symbolic"
                onTriggered: {
                    var r = StoandlClient.extUninstall(uninstallConfirm.extName, keepConfigBox.checked);
                    if (r.kind !== "ok")
                        page.toast("Uninstall failed: " + (r.tail || r.kind));
                    else
                        page.toast("Uninstalled " + uninstallConfirm.extName);
                    StoandlClient.refreshExtensions(); // re-fetch after mutation
                    uninstallConfirm.close();
                }
            },
            Kirigami.Action {
                text: "Cancel"
                icon.name: "dialog-cancel-symbolic"
                onTriggered: uninstallConfirm.close()
            }
        ]
    }

    // --- extension schema-config form dialog -------------------------------
    Kirigami.Dialog {
        id: extConfigDialog
        title: "Extension settings"
        preferredWidth: Kirigami.Units.gridUnit * 25
        standardButtons: QQC2.Dialog.NoButton
        showCloseButton: true

        property string extName: ""
        property var fields: []
        property var values: ({})

        function openFor(name) {
            extName = name;
            title = name + " settings";
            fields = StoandlClient.extConfigSchema(name);
            var got = StoandlClient.extGetConfig(name);
            values = (got && got.values) ? got.values : ({});
            open();
        }

        // Collect current control values keyed by field key.
        function collect() {
            var out = {};
            for (var i = 0; i < fieldRepeater.count; ++i) {
                var item = fieldRepeater.itemAt(i);
                if (item && item.fieldKey !== "")
                    out[item.fieldKey] = item.fieldValue;
            }
            return out;
        }

        FormCard.FormCard {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 25

            Repeater {
                id: fieldRepeater
                model: extConfigDialog.fields

                delegate: FormCard.AbstractFormDelegate {
                    id: fieldRow
                    required property var modelData

                    // Exposed for collect(): the field's key + current value.
                    readonly property string fieldKey: modelData.key
                    property var fieldValue: extConfigDialog.values[modelData.key]

                    background: null
                    hoverEnabled: false
                    Accessible.name: modelData.label

                    contentItem: ColumnLayout {
                        spacing: 0

                        // bool -> switch
                        FormCard.FormSwitchDelegate {
                            visible: fieldRow.modelData.type === "bool"
                            Layout.fillWidth: true
                            background: null
                            text: fieldRow.modelData.label
                            checked: fieldRow.fieldValue === true || fieldRow.fieldValue === "true"
                            onToggled: fieldRow.fieldValue = checked
                        }

                        // string -> text field (password echo when secret)
                        FormCard.FormTextFieldDelegate {
                            visible: fieldRow.modelData.type === "string"
                            Layout.fillWidth: true
                            label: fieldRow.modelData.label
                            text: fieldRow.fieldValue !== undefined ? "" + fieldRow.fieldValue : ""
                            echoMode: fieldRow.modelData.secret ? TextInput.Password : TextInput.Normal
                            onTextChanged: fieldRow.fieldValue = text
                        }

                        // int -> spin box
                        FormCard.FormSpinBoxDelegate {
                            visible: fieldRow.modelData.type === "int"
                            Layout.fillWidth: true
                            label: fieldRow.modelData.label
                            from: -1000000
                            to: 1000000
                            value: fieldRow.fieldValue !== undefined ? parseInt(fieldRow.fieldValue) : 0
                            onValueChanged: fieldRow.fieldValue = value
                        }

                        // enum -> combo box
                        FormCard.FormComboBoxDelegate {
                            visible: fieldRow.modelData.type === "enum"
                            Layout.fillWidth: true
                            text: fieldRow.modelData.label
                            model: fieldRow.modelData.options
                            currentIndex: {
                                var opts = fieldRow.modelData.options || [];
                                var idx = opts.indexOf(fieldRow.fieldValue);
                                return idx >= 0 ? idx : 0;
                            }
                            onCurrentValueChanged: fieldRow.fieldValue = currentValue
                        }
                    }
                }
            }
        }

        customFooterActions: [
            Kirigami.Action {
                text: "Save"
                icon.name: "document-save-symbolic"
                onTriggered: {
                    var r = StoandlClient.extSetConfig(extConfigDialog.extName, extConfigDialog.collect());
                    if (r.kind === "ok")
                        page.toast("Saved " + extConfigDialog.extName + " settings");
                    else
                        page.toast("Save failed: " + (r.tail || r.kind));
                    StoandlClient.refreshExtensions(); // re-fetch after mutation
                    extConfigDialog.close();
                }
            },
            Kirigami.Action {
                text: "Cancel"
                icon.name: "dialog-cancel-symbolic"
                onTriggered: extConfigDialog.close()
            }
        ]
    }

    // --- install .pbw (faces / apps) ---------------------------------------
    Dialogs.FileDialog {
        id: pbwFileDialog
        title: "Install watchapp / watchface (.pbw)"
        nameFilters: ["Pebble apps (*.pbw)"]
        onAccepted: {
            var r = StoandlClient.sideloadApp(selectedFile); // absolute daemon-side path (co-located)
            if (!r.ok)
                page.toast("Install failed: " + (r.tail || r.kind));
            else
                page.toast("Installed");
            StoandlClient.refreshApps(); // re-fetch after mutation
        }
    }

    // --- install extension archive -----------------------------------------
    Dialogs.FileDialog {
        id: extFileDialog
        title: "Install extension"
        nameFilters: ["Extension archives (*.tar.gz *.tgz *.tar *.zip)"]
        onAccepted: {
            var r = StoandlClient.extInstall(selectedFile); // absolute daemon-side path (co-located)
            if (r.kind !== "ok")
                page.toast("Install failed: " + (r.tail || r.kind));
            else
                page.toast("Extension installed");
            StoandlClient.refreshExtensions(); // re-fetch after mutation
        }
    }
}
