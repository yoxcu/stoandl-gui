import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// Settings -> Debug -> Heartbeat. Developer view of the watch's hourly analytics heartbeat: the
// record header (time / size / version / build-id / firmware) and every metric the daemon decoded
// from it, grouped by the name prefix before the first '_'. Read-only.
//
// The watch logs one record about once an hour, so there is no poll — the page has a Refresh
// action instead. When the daemon reports known = 0 it has no verified layout for that
// (size, version): the record is still captured and stored raw, but NO metrics are listed,
// because stoandl never shows guessed values. The daemon reads the stored record of the CONNECTED
// watch (it resolves the watch argument among connected ones), so with none connected it answers
// `unknown:` — shown as "no watch connected", not as "nothing captured".
Kirigami.ScrollablePage {
    id: page
    objectName: "heartbeat"
    title: "Heartbeat"

    property var info: null      // heartbeatInfo() map (null before the first fetch)
    property var groups: []      // heartbeatMetrics(): [{group, label, metrics:[…]}]
    property string query: ""    // metric-name filter (header search field)
    property bool watchConnected: true   // latest ListWatches verdict; tells the two `unknown:` cases apart

    readonly property bool hasInfo: page.info !== null && page.info.ok === true
    // The daemon has a verified layout for this record — only then are there metrics to show.
    readonly property bool known: page.hasInfo && page.info.known === true
    readonly property string layoutLabel: page.hasInfo ? (page.info.size + " B · v" + page.info.version) : ""
    readonly property string recordTime: (page.hasInfo && page.info.watchTs > 0)
        ? Qt.formatDateTime(new Date(page.info.watchTs * 1000), "yyyy-MM-dd hh:mm")
        : "—"
    readonly property string receivedTime: (page.hasInfo && page.info.rx > 0)
        ? Qt.formatDateTime(new Date(page.info.rx * 1000), "yyyy-MM-dd hh:mm")
        : "—"

    // Name filter, applied to the already-parsed groups (no re-fetch per keystroke). Groups whose
    // metrics all filter out drop away with them.
    readonly property var shownGroups: {
        var q = page.query.toLowerCase();
        if (q === "")
            return page.groups;
        var out = [];
        for (var i = 0; i < page.groups.length; ++i) {
            var g = page.groups[i];
            var ms = [];
            for (var j = 0; j < g.metrics.length; ++j) {
                if (g.metrics[j].name.toLowerCase().indexOf(q) >= 0)
                    ms.push(g.metrics[j]);
            }
            if (ms.length > 0)
                out.push({ "group": g.group, "label": g.label, "metrics": ms });
        }
        return out;
    }

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    function applyWatches(rows) {
        var found = false;
        for (var i = 0; i < rows.length; ++i) {
            if (rows[i].connected) { found = true; break; }
        }
        page.watchConnected = found;
    }

    function reload() {
        if (!StoandlClient.daemonUp) { page.info = null; page.groups = []; return; }
        page.applyWatches(StoandlClient.listWatches());
        page.info = StoandlClient.heartbeatInfo("");
        // Empty by contract for an unverified layout / a watch with no heartbeat yet.
        page.groups = StoandlClient.heartbeatMetrics("");
    }

    Connections {
        target: StoandlClient
        function onDaemonUpChanged() { if (StoandlClient.daemonUp) page.reload(); }
        // A (re)connect makes the connected watch's record readable; a disconnect makes it unreadable.
        function onWatchesChanged(rows) {
            var was = page.watchConnected;
            page.applyWatches(rows);
            if (page.watchConnected !== was)
                page.reload();
        }
    }

    // Headless smoke (STOANDL_SMOKE_MS): the name filter only runs once something is typed.
    function smokeExercise() {
        searchField.text = "battery";   // onTextChanged → page.query
        console.log("stoandl-smoke: heartbeat kind=" + (page.info ? page.info.kind : "none")
                    + " watchConnected=" + page.watchConnected + " groups=" + page.groups.length
                    + " shown=" + page.shownGroups.length + " known=" + page.known);
    }

    Component.onCompleted: page.reload()

    // A label / value fact row (mirrors the watch-details dialog's DetailRow, as a form delegate).
    component FactRow: FormCard.AbstractFormDelegate {
        id: fact
        property string label
        property string value
        property bool mono: false
        Layout.fillWidth: true
        background: null
        hoverEnabled: false
        contentItem: RowLayout {
            spacing: Kirigami.Units.largeSpacing
            QQC2.Label { text: fact.label; opacity: 0.7 }
            QQC2.Label {
                Layout.fillWidth: true
                text: fact.value
                horizontalAlignment: Text.AlignRight
                font.family: fact.mono ? "monospace" : Kirigami.Theme.defaultFont.family
                font.bold: true
                elide: Text.ElideRight
            }
        }
    }

    actions: [
        Kirigami.Action {
            icon.name: "view-refresh-symbolic"
            text: "Refresh"
            enabled: StoandlClient.daemonUp
            onTriggered: { page.reload(); page.toast("Refreshed"); }
        }
    ]

    // Filter stays pinned while the (long) metric list scrolls.
    header: QQC2.ToolBar {
        visible: StoandlClient.daemonUp && page.groups.length > 0
        height: visible ? implicitHeight : 0
        position: QQC2.ToolBar.Header
        contentItem: Kirigami.SearchField {
            id: searchField
            placeholderText: "Filter metrics"
            onTextChanged: page.query = text
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

        // --- heartbeat capture disabled daemon-side (notready:) ------------
        Kirigami.PlaceholderMessage {
            visible: StoandlClient.daemonUp && page.info !== null && page.info.kind === "notready"
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
            icon.name: "dialog-information-symbolic"
            text: "Heartbeat capture is off"
            explanation: "The daemon is not capturing analytics heartbeats, so there is no record to inspect. Turn on “Battery insights” in Settings → Daemon configuration."
        }

        // --- no record for this watch yet (unknown:<label>) -----------------
        Kirigami.PlaceholderMessage {
            visible: StoandlClient.daemonUp && page.info !== null && page.info.kind === "unknown"
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
            icon.name: "chronometer-symbolic"
            // With no watch connected the daemon has nothing to resolve the request to, whatever it
            // stored earlier; otherwise `label` is the connected watch's name.
            text: page.watchConnected ? "No heartbeat captured yet" : "No watch connected"
            explanation: page.watchConnected
                ? "The watch logs one analytics record about once an hour while connected. None has been captured yet"
                  + ((page.info && page.info.label) ? (" for " + page.info.label + ".") : ".")
                : "stoandl shows the newest heartbeat of the connected watch. Connect it to see its record."
        }

        // --- the call itself failed ----------------------------------------
        Kirigami.PlaceholderMessage {
            visible: StoandlClient.daemonUp && page.info !== null && page.info.kind !== "ok"
                     && page.info.kind !== "notready" && page.info.kind !== "unknown"
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
            icon.name: "dialog-error-symbolic"
            text: "Could not read the heartbeat"
            explanation: (page.info && page.info.tail) ? page.info.tail : "The daemon returned an error."
        }

        // --- unverified layout: captured, but deliberately not decoded ------
        Kirigami.InlineMessage {
            visible: StoandlClient.daemonUp && page.hasInfo && !page.known
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.largeSpacing
            Layout.leftMargin: Kirigami.Units.largeSpacing
            Layout.rightMargin: Kirigami.Units.largeSpacing
            type: Kirigami.MessageType.Warning
            text: "This firmware writes a heartbeat layout stoandl has not verified (" + page.layoutLabel + "). "
                  + "The record IS still being captured and stored raw — nothing is lost — but no metrics are shown: "
                  + "stoandl never displays guessed values. Adding this layout decodes the stored history retroactively."
        }

        // --- record header --------------------------------------------------
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp && page.hasInfo
            title: "Record"
        }
        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.hasInfo

            FactRow { label: "Recorded";  value: page.recordTime }
            FactRow { label: "Received";  value: page.receivedTime }
            FactRow { label: "Firmware";  value: (page.hasInfo && page.info.fw) ? page.info.fw : "—" }
            FactRow { label: "Layout";    value: page.layoutLabel }
            // The GNU build-id of the exact firmware build — NOT a git SHA, so it can't be looked up.
            FactRow { label: "Build ID";  value: (page.hasInfo && page.info.buildId) ? page.info.buildId : "—"; mono: true }
            FactRow {
                label: "Metrics"
                value: page.known ? String(page.info.metricCount) : "not decoded"
            }
        }

        // --- metrics, grouped by name prefix --------------------------------
        Repeater {
            model: page.shownGroups

            delegate: ColumnLayout {
                id: groupRow
                required property var modelData
                Layout.fillWidth: true
                spacing: 0

                FormCard.FormHeader {
                    title: groupRow.modelData.label
                }

                FormCard.FormCard {
                    Repeater {
                        model: groupRow.modelData.metrics

                        delegate: FormCard.AbstractFormDelegate {
                            id: metricRow
                            required property var modelData
                            Layout.fillWidth: true
                            background: null
                            hoverEnabled: false

                            contentItem: RowLayout {
                                spacing: Kirigami.Units.largeSpacing

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0
                                    QQC2.Label {
                                        Layout.fillWidth: true
                                        text: metricRow.modelData.name
                                        font.family: "monospace"
                                        elide: Text.ElideRight
                                    }
                                    // Scaled metrics divide the wire integer — show the raw one too.
                                    QQC2.Label {
                                        Layout.fillWidth: true
                                        visible: metricRow.modelData.rawDiffers
                                        text: "raw " + metricRow.modelData.raw
                                        font: Kirigami.Theme.smallFont
                                        opacity: 0.7
                                        elide: Text.ElideRight
                                    }
                                }

                                QQC2.Label {
                                    Layout.fillWidth: true
                                    text: metricRow.modelData.display
                                    horizontalAlignment: Text.AlignRight
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }
                }
            }
        }

        // --- decoded layout, but the daemon returned no metric rows ---------
        Kirigami.PlaceholderMessage {
            visible: StoandlClient.daemonUp && page.known && page.groups.length === 0
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
            icon.name: "dialog-information-symbolic"
            text: "No metrics"
            explanation: "The daemon decoded the record but reported no metrics for it."
        }

        // --- everything filtered out ----------------------------------------
        Kirigami.PlaceholderMessage {
            visible: StoandlClient.daemonUp && page.groups.length > 0 && page.shownGroups.length === 0
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
            icon.name: "search-symbolic"
            text: "No matching metrics"
            explanation: "No metric name contains “" + page.query + "”."
        }

        FormCard.FormSectionText {
            visible: StoandlClient.daemonUp && page.hasInfo
            text: "The watch logs one analytics record per hour and the daemon stores it whole, so this page only changes about once an hour. Values are shown exactly as the firmware reports them."
        }
    }
}
