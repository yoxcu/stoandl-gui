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
    // Latest PluginList snapshot (empty while plugins are off) and pending permission requests.
    property var plugins: []
    property var permRequests: []
    // Requests not put off, grouped per app: [{appUuid, appName, running, keys[], labels[]}]. PermPending
    // covers apps that aren't running too; "Later" (seen) hides a request here but not from the app's badge.
    readonly property var permGroups: {
        const byApp = {}
        const order = []
        permRequests.filter(function (r) { return !r.seen }).forEach(function (r) {
            if (!byApp[r.appUuid]) { byApp[r.appUuid] = { appUuid: r.appUuid, appName: r.appName, running: false, keys: [], labels: [] }; order.push(r.appUuid) }
            byApp[r.appUuid].running = byApp[r.appUuid].running || r.running
            byApp[r.appUuid].keys.push(r.key)
            byApp[r.appUuid].labels.push(r.label)
        })
        return order.map(function (u) { return byApp[u] })
    }
    // Apps with any waiting request, put off or not (the badge on their Permissions button).
    readonly property var permWaitingApps: permRequests.map(function (r) { return r.appUuid })
    // PluginList is empty exactly while plugins (and so permissions) are off.
    readonly property bool pluginsOn: plugins.length > 0
    // Plugins not served by an extension (an extension's plugin is part of its own row).
    readonly property var appPlugins: plugins.filter(function (p) { return p.kind !== "extension"; })

    readonly property bool extSegment: segment === "ext"

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    // Asynchronous: the lists arrive through the signals below.
    function reload() {
        StoandlClient.refreshApps();
        StoandlClient.refreshExtensions();
        StoandlClient.refreshPlugins();
    }

    // Kept while another tab shows (Main.qml): re-read when it comes back.
    function refreshOnShow() { page.reload(); }

    // --- Permissions ---------------------------------------------------------
    function answer(group, allow) {
        var failed = 0;
        group.keys.forEach(function (k) {
            var r = StoandlClient.permSet(group.appUuid, k, allow ? "allow" : "deny");
            if (!r.ok) failed++;
        });
        page.toast(failed ? "Couldn't answer " + failed + " request(s)" : (allow ? "Allowed " : "Denied ") + group.appName);
        StoandlClient.refreshPlugins();
    }
    function putOff(group) {
        var r = StoandlClient.permSet(group.appUuid, "", "later");
        page.toast(r.ok ? "Won't ask about " + group.appName + " for now" : "Couldn't put off: " + (r.tail || r.kind));
        StoandlClient.refreshPlugins();
    }

    function pluginKindLabel(kind) {
        return kind === "builtin" ? "Built-in" : kind === "extension" ? "Extension" : "App";
    }

    /** What an extension's plugin serves, as one line ("" when it serves none). */
    function extensionServes(name) {
        for (var i = 0; i < page.plugins.length; ++i) {
            var p = page.plugins[i];
            if (p.kind === "extension" && p.name.toLowerCase() === name.toLowerCase())
                return "serves " + p.sources.concat(p.actions).join(", ");
        }
        return "";
    }

    // --- Faces / Apps actions ---------------------------------------------
    function doLaunch(app) {
        var r = StoandlClient.launchApp(app.uuid);
        if (!r.ok)
            page.toast("Launch failed: " + (r.tail || r.kind));
        else
            page.toast("Launched " + app.title);
        // A face launch changes the active flag: the daemon's LockerChanged re-reads the list.
    }

    function doRemove(app) {
        var r = StoandlClient.removeApp(app.uuid);
        if (!r.ok)
            page.toast("Remove failed: " + (r.tail || r.kind));
        // The removal changes the locker: the daemon's LockerChanged re-reads the list.
    }

    function doConfig(app) {
        var r = StoandlClient.openConfig(app.uuid);
        if (r.kind === "ok" && r.opened)
            page.toast("Opening config in your browser…");
        else if (r.kind === "none")
            page.toast("No settings page — is the watch connected?");
        else
            page.toast("Config unavailable: " + (r.msg || r.kind));
    }

    // --- Reordering (faces/apps) ------------------------------------------
    // Order is per-type (faces and apps are ranked separately), and the daemon repacks the neighbours,
    // so a move is just "take this item to the neighbour's slot". The moved order syncs to the watch menu.
    function siblingsOf(app) { return app.isFace ? page.faces : page.others; }
    function indexOfUuid(list, uuid) {
        for (var k = 0; k < list.length; ++k)
            if (list[k].uuid === uuid) return k;
        return -1;
    }
    function applyOrder(uuid, order) {
        var r = StoandlClient.setAppOrder(uuid, order);
        if (!r.ok) page.toast("Reorder failed: " + (r.tail || r.kind));
        StoandlClient.refreshApps(); // re-fetch after mutation (no LockerChanged for reorder yet)
    }
    function moveUp(app) {
        var list = page.siblingsOf(app);
        var i = page.indexOfUuid(list, app.uuid);
        if (i > 0) page.applyOrder(app.uuid, list[i - 1].order);
    }
    function moveDown(app) {
        var list = page.siblingsOf(app);
        var i = page.indexOfUuid(list, app.uuid);
        if (i >= 0 && i < list.length - 1) page.applyOrder(app.uuid, list[i + 1].order);
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
        // An unchanged list (the re-read on show, a LockerChanged that only confirms a refresh) keeps
        // the rows instead of rebuilding them.
        function onAppsChanged(rows) { if (JSON.stringify(rows) !== JSON.stringify(page.apps)) page.apps = rows; }
        function onExtensionsChanged(rows) { page.extensions = rows; }
        function onPluginsChanged(rows) { page.plugins = rows; }
        function onPermissionRequestsChanged(rows) { page.permRequests = rows; }
    }
    Connections {
        target: StoandlClient
        enabled: page.visible   // a hidden page re-reads in refreshOnShow()
        function onDaemonUpChanged() {
            if (StoandlClient.daemonUp)
                page.reload();
        }
    }

    // Re-fetch on show + after every mutation the daemon doesn't announce with LockerChanged.
    Component.onCompleted: page.reload()

    // Read-only (it also runs against a real daemon): an extension's settings form (its fields' subtitles,
    // help and the values Save would send), the request banners, then one app's permission dialog.
    function smokeExercise() {
        if (!StoandlClient.daemonUp) return;
        var ext = page.extensions.find(function (e) { return e.config === "schema" && e.installed; });
        if (ext) {
            extConfigDialog.openFor(ext.name);
            console.log("stoandl-smoke: ext config " + ext.name + " " + extConfigDialog.fields.map(function (f) {
                return f.key + (f.description ? "[desc]" : "") + (f.help ? "[help]" : ""); }).join(", ")
                + " · save " + JSON.stringify(extConfigDialog.collect()));
            extConfigDialog.close();
        }
        console.log("stoandl-smoke: perm banners " + page.permGroups.map(function (g) {
            return g.appName + (g.running ? "" : "(closed)") }).join(", ") + " · waiting apps " + page.permWaitingApps.length);
        var uuid = page.permWaitingApps.length > 0 ? page.permWaitingApps[0] : (page.apps.length > 0 ? page.apps[0].uuid : "");
        if (uuid === "") return;
        permDialog.openFor(uuid, "smoke", page.pluginsOn);
        console.log("stoandl-smoke: perms " + permDialog.rows.map(function (r) { return r.key + "=" + r.status }).join(", ")
                    + " · unseen waiting " + permDialog.unseenWaiting);
        permDialog.close();
    }

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
        },
        Kirigami.Action {
            icon.name: "edit-reset-symbolic"
            // Resets the built-in system apps/faces to their default order (RestoreSystemAppOrder only
            // touches system entries; sideloaded ones keep their positions).
            text: "Restore default order"
            visible: !page.extSegment
            enabled: StoandlClient.daemonUp
            onTriggered: {
                var r = StoandlClient.restoreSystemAppOrder();
                page.toast(r.ok ? "System apps restored to default order" : ("Reset failed: " + (r.tail || r.kind)));
                StoandlClient.refreshApps();
            }
        }
    ]

    // --- One reusable row for both the Faces and Apps segments -------------
    component AppRow: FormCard.AbstractFormDelegate {
        id: row
        required property var appData
        // Position within its (faces|apps) list, for the up/down move buttons.
        property int rowIndex: 0
        property int rowCount: 0

        // The app's extracted menu-icon PNG (file:// URL), from StoandlClient's cache or, on a miss,
        // asked asynchronously (appIconChanged). Empty until resolved or when the daemon has no icon —
        // then we show a generic glyph.
        property string iconUrl: ""
        Component.onCompleted: row.iconUrl = StoandlClient.appIcon(row.appData.uuid)
        Connections {
            target: StoandlClient
            function onAppIconChanged(uuid, url) { if (uuid === row.appData.uuid) row.iconUrl = url; }
        }

        onClicked: page.doLaunch(appData)

        contentItem: RowLayout {
            spacing: Kirigami.Units.largeSpacing

            // Extracted menu icon when available, otherwise a themed generic glyph. Menu bitmaps are tiny
            // (~25 px, daemon-flattened to black-on-white); render at a clean integer 2× with no smoothing
            // so the hard edges stay pixel-exact instead of being mangled by a fractional stretch.
            Item {
                implicitWidth: Kirigami.Units.iconSizes.huge
                implicitHeight: Kirigami.Units.iconSizes.huge

                Image {
                    id: menuIcon
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth * 2, parent.width)
                    height: Math.min(implicitHeight * 2, parent.height)
                    source: row.iconUrl
                    visible: row.iconUrl !== "" && status === Image.Ready
                    fillMode: Image.PreserveAspectFit
                    smooth: false
                    asynchronous: true
                    cache: true
                }

                Kirigami.Icon {
                    anchors.centerIn: parent
                    width: Kirigami.Units.iconSizes.large
                    height: Kirigami.Units.iconSizes.large
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
                    // Author (or uuid fallback), with the locker version beside it when known.
                    text: {
                        const who = row.appData.developer !== "" ? row.appData.developer : row.appData.uuid
                        return row.appData.version !== "" ? who + " · v" + row.appData.version : who
                    }
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

            // The app's permissions (plugins on, or while it has a request waiting), badged while one waits.
            QQC2.ToolButton {
                id: permButton
                readonly property bool waiting: page.permWaitingApps.indexOf(row.appData.uuid) >= 0
                visible: page.pluginsOn || waiting
                icon.name: "security-medium-symbolic"
                display: QQC2.AbstractButton.IconOnly
                QQC2.ToolTip.text: waiting ? "Permissions · waiting for your answer" : "Permissions"
                QQC2.ToolTip.visible: hovered
                onClicked: permDialog.openFor(row.appData.uuid, row.appData.title, page.pluginsOn)
                Rectangle {
                    visible: permButton.waiting
                    width: Kirigami.Units.smallSpacing * 2
                    height: width
                    radius: width / 2
                    color: Kirigami.Theme.neutralTextColor
                    anchors { top: parent.top; right: parent.right; margins: Kirigami.Units.smallSpacing }
                }
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

            // Reorder within the faces/apps list. Kept RIGHTMOST (after the optional settings/delete
            // buttons) so the up/down column lines up on every row regardless of which of those a given
            // app has. The move persists to the watch menu (locker BlobDB).
            QQC2.ToolButton {
                visible: row.rowCount > 1
                enabled: row.rowIndex > 0
                icon.name: "go-up-symbolic"
                display: QQC2.AbstractButton.IconOnly
                QQC2.ToolTip.text: "Move up"
                QQC2.ToolTip.visible: hovered
                onClicked: page.moveUp(row.appData) // consumes click -> no row launch
            }
            QQC2.ToolButton {
                visible: row.rowCount > 1
                enabled: row.rowIndex < row.rowCount - 1
                icon.name: "go-down-symbolic"
                display: QQC2.AbstractButton.IconOnly
                QQC2.ToolTip.text: "Move down"
                QQC2.ToolTip.visible: hovered
                onClicked: page.moveDown(row.appData)
            }
        }
    }

    // Pinned segment switcher (Faces / Apps / Plugins) — stays at the top while the list scrolls. The Plugins
    // segment lists the plugins (built-in, from installed apps) and the extensions (host-side companions,
    // which can serve plugins too).
    header: QQC2.ToolBar {
        visible: StoandlClient.daemonUp
        height: visible ? implicitHeight : 0
        position: QQC2.ToolBar.Header
        contentItem: RowLayout {
            spacing: Kirigami.Units.smallSpacing
            QQC2.Button {
                Layout.fillWidth: true
                text: "Faces · " + page.faces.length
                checkable: true; autoExclusive: true
                checked: page.segment === "faces"
                onClicked: page.segment = "faces"
            }
            QQC2.Button {
                Layout.fillWidth: true
                text: "Apps · " + page.others.length
                checkable: true; autoExclusive: true
                checked: page.segment === "apps"
                onClicked: page.segment = "apps"
            }
            QQC2.Button {
                Layout.fillWidth: true
                text: "Plugins · " + (page.appPlugins.length + page.extensions.length)
                checkable: true; autoExclusive: true
                checked: page.segment === "ext"
                onClicked: page.segment = "ext"
            }
        }
    }

    ColumnLayout {
        spacing: 0

        // --- Permission requests (plugins on): one banner per app, on every segment ---
        Repeater {
            model: StoandlClient.daemonUp ? page.permGroups : []
            delegate: Kirigami.InlineMessage {
                required property var modelData
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                visible: true
                type: Kirigami.MessageType.Warning
                text: modelData.appName + " asks for: " + modelData.labels.join(", ")
                      + (modelData.running ? "" : " (asked earlier, while it was open)")
                actions: [
                    Kirigami.Action {
                        text: "Allow"
                        icon.name: "dialog-ok-apply-symbolic"
                        onTriggered: page.answer(modelData, true)
                    },
                    Kirigami.Action {
                        text: "Deny"
                        icon.name: "dialog-cancel-symbolic"
                        onTriggered: page.answer(modelData, false)
                    },
                    Kirigami.Action {
                        text: "Later"
                        icon.name: "appointment-soon-symbolic"
                        tooltip: "Stop asking for now, without deciding"
                        onTriggered: page.putOff(modelData)
                    },
                    Kirigami.Action {
                        text: "Review"
                        icon.name: "security-medium-symbolic"
                        onTriggered: permDialog.openFor(modelData.appUuid, modelData.appName, page.pluginsOn)
                    }
                ]
            }
        }

        // --- daemon-not-running state --------------------------------------
        DaemonPlaceholder {
            visible: !StoandlClient.daemonUp
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
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
                model: page.segment === "faces" ? page.faces : []   // rows only for the segment shown
                delegate: AppRow {
                    required property var modelData
                    required property int index
                    appData: modelData
                    rowIndex: index
                    rowCount: page.faces.length
                }
            }
        }

        // --- Apps list -----------------------------------------------------
        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.segment === "apps" && page.others.length > 0
            Layout.topMargin: Kirigami.Units.largeSpacing

            Repeater {
                model: page.segment === "apps" ? page.others : []
                delegate: AppRow {
                    required property var modelData
                    required property int index
                    appData: modelData
                    rowIndex: index
                    rowCount: page.others.length
                }
            }
        }

        // --- Plugins (built-in and from installed apps) ----------------------
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp && page.extSegment
            title: "Plugins"
        }
        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.extSegment
            FormCard.FormTextDelegate {
                visible: page.appPlugins.length === 0
                text: "No plugins"
                description: "Plugins are off (Settings → Apps & plugins), or none are installed. They give watchfaces and watchapps data and actions from this computer: weather, music, calendar, phone state, or a plugin an app brings."
            }
            Repeater {
                model: page.appPlugins
                delegate: FormCard.FormTextDelegate {
                    id: pluginRow
                    required property var modelData
                    text: modelData.name
                    description: page.pluginKindLabel(modelData.kind) + " · "
                        + (modelData.description !== "" ? modelData.description + " · " : "")
                        + (modelData.sources.length ? "data: " + modelData.sources.join(", ") : "")
                        + (modelData.actions.length ? (modelData.sources.length ? " · " : "") + "actions: " + modelData.actions.join(", ") : "")
                    trailing: QQC2.ToolButton {
                        visible: pluginRow.modelData.kind === "pbw"
                        icon.name: "configure-symbolic"
                        display: QQC2.AbstractButton.IconOnly
                        QQC2.ToolTip.text: "Settings"
                        QQC2.ToolTip.visible: hovered
                        onClicked: page.doConfig({ uuid: pluginRow.modelData.uuid })
                    }
                }
            }
        }

        FormCard.FormHeader {
            visible: StoandlClient.daemonUp && page.extSegment && page.extensions.length > 0
            title: "Extensions"
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
                    // Author · vVersion (like the apps/faces subtitle), then the manifest description.
                    description: {
                        const parts = []
                        if (modelData.author && modelData.author !== "")
                            parts.push(modelData.author)
                        if (modelData.version && modelData.version !== "")
                            parts.push("v" + modelData.version)
                        const head = parts.join(" · ")
                        const serves = page.extensionServes(modelData.name)
                        let text = head
                        if (modelData.description && modelData.description !== "")
                            text = head !== "" ? head + " — " + modelData.description : modelData.description
                        return serves !== "" ? (text !== "" ? text + " · " + serves : serves) : text
                    }
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
            text: "Extensions are host-side companions that drive watch notifications with quick replies and actions, and can serve plugin data to watchfaces and watchapps."
        }
    }

    AppPermissionsDialog { id: permDialog }

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
    // One row per field of the manifest's configSchema; a field's optional `description` is the row's
    // subtitle and its optional `help` sits behind the row's (?).
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

        // The enum rows' picker, built on first use.
        function pick(title, options, index, onPicked) {
            extPickerLoader.active = true;
            extPickerLoader.item.choose(title, options, index, onPicked);
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
                    // A secret lives in the daemon's keyring and always reads "": posting "" keeps it,
                    // null removes it. `_secrets` names the stored ones.
                    readonly property bool isSecret: modelData.type === "string" && modelData.secret === true
                    readonly property bool secretStored: isSecret && !secretCleared &&
                        ("" + (extConfigDialog.values["_secrets"] || "")).split(",").indexOf(modelData.key) >= 0
                    property bool secretCleared: false

                    background: null
                    hoverEnabled: false
                    Accessible.name: modelData.label

                    // Every row holds one control per type and shows the field's; only that one writes
                    // fieldValue (a hidden text row would turn every value into a string).
                    contentItem: ColumnLayout {
                        spacing: 0

                        // bool -> switch
                        FormSwitchRow {
                            visible: fieldRow.modelData.type === "bool"
                            Layout.fillWidth: true
                            background: null
                            text: fieldRow.modelData.label
                            description: fieldRow.modelData.description
                            help: fieldRow.modelData.help
                            checked: fieldRow.fieldValue === true || fieldRow.fieldValue === "true"
                            onToggled: fieldRow.fieldValue = checked
                        }

                        // string -> text field
                        FormTextRow {
                            visible: fieldRow.modelData.type === "string" && !fieldRow.isSecret
                            Layout.fillWidth: true
                            label: fieldRow.modelData.label
                            description: fieldRow.modelData.description
                            help: fieldRow.modelData.help
                            value: fieldRow.fieldValue !== undefined ? "" + fieldRow.fieldValue : ""
                            onValueChanged: if (fieldRow.modelData.type === "string" && !fieldRow.isSecret) fieldRow.fieldValue = value
                        }

                        // secret string -> password field, blank unless retyped, plus Clear when stored
                        FormTextRow {
                            visible: fieldRow.isSecret
                            Layout.fillWidth: true
                            label: fieldRow.modelData.label
                            help: fieldRow.modelData.help
                            description: (fieldRow.modelData.description !== "" ? fieldRow.modelData.description + " · " : "")
                                + (fieldRow.secretStored ? "Stored in the keyring; type to replace it"
                                   : fieldRow.secretCleared ? "Will be removed on Save" : "Not set")
                            echoMode: TextInput.Password
                            placeholderText: fieldRow.secretStored ? "••••••••" : ""
                            onValueChanged: if (fieldRow.isSecret) fieldRow.fieldValue = (value === "" && fieldRow.secretCleared) ? null : value
                        }
                        FormCard.FormButtonDelegate {
                            visible: fieldRow.secretStored
                            text: "Clear " + fieldRow.modelData.label
                            onClicked: {
                                fieldRow.secretCleared = true;
                                fieldRow.fieldValue = null;
                            }
                        }

                        // int -> spin box (Save reads what it shows, not its debounced commit)
                        FormSpinRow {
                            visible: fieldRow.modelData.type === "int"
                            Layout.fillWidth: true
                            label: fieldRow.modelData.label
                            description: fieldRow.modelData.description
                            help: fieldRow.modelData.help
                            from: -1000000
                            to: 1000000
                            value: fieldRow.fieldValue !== undefined ? parseInt(fieldRow.fieldValue) || 0 : 0
                            onShownValueChanged: if (fieldRow.modelData.type === "int") fieldRow.fieldValue = shownValue
                        }

                        // enum -> option row and the dialog's picker; an unknown stored value shows the first
                        // option, which Save then writes
                        FormOptionRow {
                            readonly property var options: fieldRow.modelData.options || []
                            readonly property int chosen: Math.max(0, options.indexOf(fieldRow.fieldValue))
                            visible: fieldRow.modelData.type === "enum"
                            Layout.fillWidth: true
                            text: fieldRow.modelData.label
                            description: fieldRow.modelData.description
                            help: fieldRow.modelData.help
                            value: options[chosen] || ""
                            Component.onCompleted: if (fieldRow.modelData.type === "enum" && options.length) fieldRow.fieldValue = options[chosen]
                            onActivated: extConfigDialog.pick(text, options, chosen,
                                                            function (i, option) { fieldRow.fieldValue = option; })
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

    // The extension settings' enum picker (extConfigDialog.pick), built on first use.
    Loader {
        id: extPickerLoader
        active: false
        sourceComponent: OptionPicker {}
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
