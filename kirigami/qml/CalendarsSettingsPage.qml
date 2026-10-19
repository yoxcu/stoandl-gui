import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import QtQuick.Dialogs as Dialogs
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// Calendars: the editable calendar *sources* (CalDAV accounts, iCal feed URLs, local .ics files) with
// their synced calendars grouped underneath their account. A CalDAV account fans out to many calendars
// (each toggleable); an iCal feed / .ics path is a single calendar. Passwords are write-only — the
// daemon stores them in the system keyring (or a local 0600 file) and never returns them, so the edit
// form's password field is blank ("leave blank to keep"). Whether local calendars are found on their own
// (calendar.discover) is a stoandl.conf key, on Settings → Calendar, which links here.
Kirigami.ScrollablePage {
    id: page
    objectName: "calendars"
    title: "Accounts and feeds"

    property var sources: []      // [{id,type,url,username,label,lastError,lastSync}]  (from ListCalendarSources)
    property var calendars: []    // [{id,name,enabled,accountId}]   (from ListCalendars)

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    // Group each calendar under its owning source (by accountId). Sources with no calendars yet still
    // show (e.g. a CalDAV account whose creds are wrong / not synced); discovered + orphan calendars
    // fall into a read-only "Discovered & other" group. Computed page-side so delegates read modelData.
    readonly property var groups: {
        var byAccount = {};
        for (var i = 0; i < page.calendars.length; ++i) {
            var c = page.calendars[i];
            var k = c.accountId || "";
            if (!byAccount[k]) byAccount[k] = [];
            byAccount[k].push(c);
        }
        var out = [];
        var claimed = {};
        for (var j = 0; j < page.sources.length; ++j) {
            var s = page.sources[j];
            claimed[s.id] = true;
            out.push({ source: s, isSource: true, calendars: byAccount[s.id] || [] });
        }
        var extras = [];
        for (var key in byAccount)
            if (!claimed[key]) extras = extras.concat(byAccount[key]);
        if (extras.length > 0)
            out.push({ source: { id: "discover", type: "discover", label: "Discovered & other", url: "", username: "" },
                       isSource: false, calendars: extras });
        return out;
    }

    function sourceIcon(type) {
        if (type === "caldav") return "folder-cloud-symbolic";
        if (type === "ical")   return "appointment-new-symbolic";
        if (type === "ics")    return "folder-symbolic";
        return "edit-find-symbolic";
    }
    // "10 min ago" for a source's last good read (epoch seconds; 0 = none since stoandl started).
    function ago(epoch) {
        var d = Math.floor(Date.now() / 1000) - epoch;
        return d < 60 ? "just now" : d < 3600 ? Math.floor(d / 60) + " min ago"
             : d < 86400 ? Math.floor(d / 3600) + " h ago" : Math.floor(d / 86400) + " days ago";
    }

    // A local path from a file dialog's URL (the daemon reads it here, on the same machine).
    function localPath(url) { return decodeURIComponent(String(url).replace(/^file:\/\//, "")); }

    function sourceTypeLabel(type) {
        if (type === "caldav") return "CalDAV account";
        if (type === "ical")   return "iCal feed";
        if (type === "ics")    return "local calendar";
        return "discovered calendars";
    }

    function reload() {
        if (!StoandlClient.daemonUp) { page.sources = []; page.calendars = []; page.refreshing = false; return; }
        StoandlClient.fetch(page, [["listCalendarSources"], ["listCalendars"]], function (r) {
            page.sources = r[0];
            page.calendars = r[1];
            page.refreshing = false;
        });
    }

    // Pull to refresh re-reads the sources and calendars; Sync now fetches them from their servers.
    supportsRefreshing: true
    onRefreshingChanged: if (refreshing) page.reload()

    function toggleCalendar(id, on) {
        var r = StoandlClient.setCalendarEnabled(id, on);
        if (!r.ok) page.toast("Calendar: " + (r.tail || r.kind));
        StoandlClient.refreshCalendars();
    }

    function openAdd()       { sourceDialog.openAdd(); }
    function openEdit(src)   { sourceDialog.openEdit(src); }
    function confirmRemove(src) { removeDialog.src = src; removeDialog.open(); }

    // After a CRUD the daemon re-syncs asynchronously (~5 s + CalDAV network discovery), so the first
    // reload races it. The CalendarsChanged signal updates us the moment it's ready; this timer is the
    // fallback — a few re-fetches over ~10 s so a slow or missed signal still self-heals.
    function settle() { settleTimer.ticks = 0; settleTimer.restart(); }
    Timer {
        id: settleTimer
        interval: 2500
        repeat: true
        property int ticks: 0
        onTriggered: { page.reload(); if (++ticks >= 4) { stop(); ticks = 0; } }
    }

    // Save the add/edit dialog. Reads the dialog's field ids (file-scoped) directly.
    function saveSource(dlg) {
        var r = (dlg.mode === "add")
            ? StoandlClient.addCalendarSource(dlg.type, urlField.value, userField.value, passField.value)
            : StoandlClient.updateCalendarSource(dlg.editId, urlField.value, userField.value, passField.value);
        if (r.kind === "ok") {
            var backend = (r.fields && r.fields.length > 1) ? r.fields[1] : "";
            var where = backend === "keyring" ? " (saved to system keyring)"
                      : backend === "file"    ? " (saved to local file — keyring unavailable)"
                      : "";
            page.toast((dlg.mode === "add" ? "Calendar added" : "Calendar updated") + where);
            dlg.close();
            page.reload();
            page.settle();   // the account's calendars land a few seconds later (async sync)
        } else {
            page.toast((dlg.mode === "add" ? "Add" : "Save") + " failed: " + (r.tail || r.kind));
        }
    }

    Connections {
        target: StoandlClient
        function onCalendarsChanged(rows) { page.calendars = rows; }
        function onDaemonUpChanged() { if (StoandlClient.daemonUp) page.reload(); }
    }

    Component.onCompleted: page.reload()

    // Smoke hook (Settings → Calendar's link runs it): each source's line on how its last read went.
    function smokeExercise() {
        console.log("stoandl-smoke: calendar sources " + page.sources.map(function (src) {
            return src.label + "=" + (src.lastError !== "" ? src.lastError : src.lastSync > 0 ? "synced " + page.ago(src.lastSync) : "-");
        }).join(", "));
    }

    actions: [
        Kirigami.Action {
            icon.name: "list-add-symbolic"
            text: "Add"
            enabled: StoandlClient.daemonUp
            onTriggered: page.openAdd()
        },
        Kirigami.Action {
            icon.name: "view-refresh-symbolic"
            text: "Sync now"
            enabled: StoandlClient.daemonUp
            onTriggered: StoandlClient.run(page, ["syncCalendar"], function (r) {
                page.toast(r.ok ? "Calendar synced" : ("Sync: " + (r.tail || r.kind)));
                page.reload();
            })
        }
    ]

    ColumnLayout {
        spacing: 0

        DaemonPlaceholder {
            visible: !StoandlClient.daemonUp
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
        }

        Kirigami.PlaceholderMessage {
            visible: StoandlClient.daemonUp && page.sources.length === 0 && page.groups.length === 0
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 3
            icon.name: "view-calendar-symbolic"
            text: "No calendars yet"
            explanation: "Add a CalDAV account, an iCal feed URL, or a local .ics file to sync calendar events to your watch."
            helpfulAction: Kirigami.Action {
                icon.name: "list-add-symbolic"
                text: "Add calendar"
                onTriggered: page.openAdd()
            }
        }

        // One card per source (account), its calendars nested below the header.
        Repeater {
            model: page.groups
            delegate: FormCard.FormCard {
                id: groupCard
                required property var modelData
                Layout.topMargin: Kirigami.Units.largeSpacing

                // Account header: icon, label + subtitle, and (for editable sources) edit/remove buttons.
                FormCard.AbstractFormDelegate {
                    Layout.fillWidth: true
                    background: null
                    hoverEnabled: false
                    contentItem: RowLayout {
                        spacing: Kirigami.Units.largeSpacing
                        Kirigami.Icon {
                            source: page.sourceIcon(groupCard.modelData.source.type)
                            Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                            Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: groupCard.modelData.source.label || groupCard.modelData.source.url || page.sourceTypeLabel(groupCard.modelData.source.type)
                                elide: Text.ElideRight
                                font.weight: Font.DemiBold
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                visible: text !== ""
                                text: {
                                    var s = groupCard.modelData.source;
                                    if (s.type === "discover") return groupCard.modelData.calendars.length + " calendar(s)";
                                    if (s.type === "caldav")   return s.username ? (s.username + " · " + s.url) : s.url;
                                    return s.url;
                                }
                                elide: Text.ElideRight
                                opacity: 0.7
                                font: Kirigami.Theme.smallFont
                            }
                            // How its last read went: the problem while there is one, else when it last worked.
                            QQC2.Label {
                                Layout.fillWidth: true
                                readonly property var src: groupCard.modelData.source
                                visible: groupCard.modelData.isSource && (src.lastError !== "" || src.lastSync > 0)
                                text: src.lastError !== "" ? src.lastError
                                    : src.lastSync > 0 ? "Last synced " + page.ago(src.lastSync) : ""
                                color: src.lastError !== "" ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
                                opacity: src.lastError !== "" ? 1 : 0.7
                                wrapMode: Text.Wrap
                                font: Kirigami.Theme.smallFont
                            }
                        }
                        QQC2.ToolButton {
                            visible: groupCard.modelData.isSource
                            icon.name: "document-edit-symbolic"
                            display: QQC2.AbstractButton.IconOnly
                            QQC2.ToolTip.text: "Edit"
                            QQC2.ToolTip.visible: hovered
                            onClicked: page.openEdit(groupCard.modelData.source)
                        }
                        QQC2.ToolButton {
                            visible: groupCard.modelData.isSource
                            icon.name: "edit-delete-symbolic"
                            display: QQC2.AbstractButton.IconOnly
                            QQC2.ToolTip.text: "Remove"
                            QQC2.ToolTip.visible: hovered
                            onClicked: page.confirmRemove(groupCard.modelData.source)
                        }
                    }
                }

                FormCard.FormDelegateSeparator { visible: groupCard.modelData.calendars.length > 0 }

                Repeater {
                    model: groupCard.modelData.calendars
                    delegate: FormCard.FormSwitchDelegate {
                        required property var modelData
                        text: modelData.name
                        checked: modelData.enabled === true
                        onToggled: page.toggleCalendar(modelData.id, checked)
                    }
                }

                FormCard.FormSectionText {
                    visible: groupCard.modelData.isSource && groupCard.modelData.calendars.length === 0
                    text: groupCard.modelData.source.type === "caldav"
                        ? "No calendars found yet — if this persists, check the URL, username and password."
                        : "No calendar found at this source yet."
                }
            }
        }
    }

    // --- Add / edit dialog --------------------------------------------------
    Kirigami.Dialog {
        id: sourceDialog
        title: "Add calendar"
        preferredWidth: applicationWindow().dialogWidth(26)
        standardButtons: QQC2.Dialog.NoButton
        showCloseButton: true

        property string mode: "add"      // add | edit
        property string editId: ""
        property string type: "caldav"   // caldav | ical | ics

        readonly property var types: ["caldav", "ical", "ics"]
        readonly property var typeLabels: ["CalDAV account", "iCal feed URL", "Local .ics file / folder"]

        function openAdd() {
            mode = "add"; editId = ""; type = "caldav";
            urlField.value = ""; userField.value = ""; passField.value = "";
            title = "Add calendar";
            open();
        }
        function openEdit(src) {
            mode = "edit"; editId = src.id; type = src.type;
            urlField.value = src.url || ""; userField.value = src.username || ""; passField.value = "";
            title = "Edit " + page.sourceTypeLabel(src.type);
            open();
        }

        FormCard.FormCard {
            Layout.preferredWidth: applicationWindow().dialogWidth(26)

            FormOptionRow {
                visible: sourceDialog.mode === "add"
                text: "Type"
                value: sourceDialog.typeLabels[sourceDialog.types.indexOf(sourceDialog.type)] || ""
                onActivated: {
                    pickerLoader.active = true;
                    pickerLoader.item.choose(text, sourceDialog.typeLabels, sourceDialog.types.indexOf(sourceDialog.type),
                                             function (i) { sourceDialog.type = sourceDialog.types[i]; });
                }
            }
            FormTextRow {
                id: urlField
                label: sourceDialog.type === "ics"  ? "File or folder path"
                     : sourceDialog.type === "ical" ? "Feed URL (https://…/calendar.ics)"
                     : "Account URL (https://dav.example.com/…)"
            }
            // A local calendar: pick the .ics file, or a folder of them, instead of typing the path.
            FormCard.FormButtonDelegate {
                visible: sourceDialog.type === "ics"
                text: "Choose a file…"
                icon.name: "document-open-symbolic"
                onClicked: icsFileDialog.open()
            }
            FormCard.FormButtonDelegate {
                visible: sourceDialog.type === "ics"
                text: "Choose a folder…"
                icon.name: "folder-open-symbolic"
                onClicked: icsFolderDialog.open()
            }
            FormTextRow {
                id: userField
                visible: sourceDialog.type === "caldav"
                label: "Username"
            }
            FormTextRow {
                id: passField
                visible: sourceDialog.type === "caldav"
                label: "Password"
                echoMode: TextInput.Password
                placeholderText: sourceDialog.mode === "edit" ? "leave blank to keep current" : ""
            }
        }

        customFooterActions: [
            Kirigami.Action {
                text: "Save"
                icon.name: "document-save-symbolic"
                onTriggered: page.saveSource(sourceDialog)
            },
            Kirigami.Action {
                text: "Cancel"
                icon.name: "dialog-cancel-symbolic"
                onTriggered: sourceDialog.close()
            }
        ]
    }

    Dialogs.FileDialog {
        id: icsFileDialog
        title: "Choose a calendar file"
        nameFilters: ["Calendars (*.ics)", "All files (*)"]
        onAccepted: urlField.value = page.localPath(selectedFile)
    }
    Dialogs.FolderDialog {
        id: icsFolderDialog
        title: "Choose a folder of calendars"
        onAccepted: urlField.value = page.localPath(selectedFolder)
    }

    // The type picker, built on first use.
    Loader {
        id: pickerLoader
        active: false
        sourceComponent: OptionPicker {}
    }

    // --- Remove confirmation ------------------------------------------------
    Kirigami.PromptDialog {
        id: removeDialog
        title: "Remove calendar source"
        property var src: ({})
        subtitle: "Remove “" + (removeDialog.src.label || removeDialog.src.url || "") + "”? Its calendars and their pins are removed from the watch. A stored CalDAV password is deleted too."
        standardButtons: QQC2.Dialog.NoButton
        customFooterActions: [
            Kirigami.Action {
                text: "Remove"
                icon.name: "edit-delete-symbolic"
                onTriggered: {
                    var r = StoandlClient.removeCalendarSource(removeDialog.src.id);
                    if (r.kind !== "ok") page.toast("Remove failed: " + (r.tail || r.kind));
                    removeDialog.close();
                    page.reload();
                    page.settle();   // its calendars drop a few seconds later (async sync)
                }
            },
            Kirigami.Action {
                text: "Cancel"
                icon.name: "dialog-cancel-symbolic"
                onTriggered: removeDialog.close()
            }
        ]
    }
}
