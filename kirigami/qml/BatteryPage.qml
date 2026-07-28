import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// Battery insights — the local equivalent of the official Core app's "Battery" screen: a big current
// reading, a battery-%-over-time chart, and headline stats. Reached from the Watch page. Data comes
// from BatteryInsights()/BatteryHistory() (heartbeat source preferred, GATT level fallback).
Kirigami.ScrollablePage {
    id: page
    objectName: "battery"
    title: "Battery"

    // Chart/history window, in seconds (the header switcher). 24 h by default.
    property int rangeSeconds: 24 * 3600
    property var insights: null       // batteryInsights() map, or null
    property var history: []          // [{ts, level, source, voltage}] oldest first
    property var activity: []         // [{ts, drop, notif, notifDnd}] oldest first (drop-per-interval)
    property double maxDrop: 0        // largest interval drop in the window (bar-chart y-scale)
    property var power: []            // [{category, estDrainPct, share}] largest share first (pie)
    property double nowSec: 0
    property double rangeStart: 0
    // Precomputed x-axis ticks [{frac, text}] — computed in reload() so the Repeater delegate reads
    // only modelData (a binding inside a delegate can't call a page method; see gui CLAUDE.md).
    property var axisTicks: []

    readonly property bool hasInsights: insights && insights.ok === true
    readonly property bool charging: hasInsights && insights.charging === true
    readonly property int level: hasInsights ? Math.round(insights.level) : 0
    // True when any interval in the window received notifications (drives the overlay caption).
    readonly property bool hasNotifs: {
        for (var i = 0; i < page.activity.length; ++i) if (page.activity[i].notif > 0) return true;
        return false;
    }
    // Total measured drain over the window (sum of the anchored per-subsystem estimates); 0 when the
    // window has no measured discharge to anchor to (then only the pie shares are meaningful).
    readonly property real powerDrainTotal: {
        var t = 0;
        for (var i = 0; i < page.power.length; ++i) t += (page.power[i].estDrainPct || 0);
        return t;
    }

    function reload() {
        if (!StoandlClient.daemonUp) { page.insights = null; page.history = []; return; }
        page.nowSec = Math.floor(Date.now() / 1000);
        page.rangeStart = page.nowSec - page.rangeSeconds;
        var span = page.nowSec - page.rangeStart;
        page.axisTicks = [
            { frac: 0.0, text: page.fmtAxis(page.rangeStart) },
            { frac: 0.5, text: page.fmtAxis(page.rangeStart + 0.5 * span) },
            { frac: 1.0, text: "now" },
        ];
        page.insights = StoandlClient.batteryInsights("");
        page.history = StoandlClient.batteryHistory("", Math.floor(page.rangeStart));
        // Set maxDrop before activity so the bar Canvas (repaints on activityChanged) has a current scale.
        var acts = StoandlClient.batteryActivity("", Math.floor(page.rangeStart));
        var md = 0;
        for (var i = 0; i < acts.length; ++i) md = Math.max(md, acts[i].drop);
        page.maxDrop = md;
        page.activity = acts;
        var pw = StoandlClient.batteryPower("", Math.floor(page.rangeStart));
        for (var j = 0; j < pw.length; ++j) pw[j].color = page.sliceColor(pw[j].category, j);
        page.power = pw;
    }

    function setRange(secs) {
        if (secs === page.rangeSeconds) return;
        page.rangeSeconds = secs;
        page.reload();
    }

    // Colour a battery level: green when healthy / charging, amber low, red critical.
    function levelColor(pct, chg) {
        if (chg) return Kirigami.Theme.positiveTextColor;
        if (pct <= 15) return Kirigami.Theme.negativeTextColor;
        if (pct <= 35) return Kirigami.Theme.neutralTextColor;
        return Kirigami.Theme.positiveTextColor;
    }

    function relAge(epoch) {
        if (!epoch || epoch <= 0) return "—";
        var d = Math.floor(Date.now() / 1000) - epoch;
        if (d < 60) return "just now";
        if (d < 3600) return Math.floor(d / 60) + "m ago";
        if (d < 86400) return Math.floor(d / 3600) + "h ago";
        return Math.floor(d / 86400) + "d ago";
    }

    function fmtAxis(epoch) {
        var d = new Date(epoch * 1000);
        return page.rangeSeconds <= 24 * 3600 ? Qt.formatTime(d, "hh:mm") : Qt.formatDate(d, "MMM d");
    }

    function sourceLabel(src) {
        if (src === "heartbeat") return "from the watch's hourly analytics heartbeat";
        if (src === "gatt") return "from the BLE battery level";
        return "";
    }

    // Stable, theme-aware colour per power-attribution category (fixed hue per subsystem so a slice keeps
    // its colour even when others drop out; hue-rotation fallback for anything unexpected). Lightened on
    // dark backgrounds. Called from reload() (a handler), not from a delegate binding — see the scope
    // gotcha in gui/CLAUDE.md; the swatch/Canvas read the precomputed modelData.color.
    function sliceColor(cat, i) {
        var hues = { "System": 0.68, "Display": 0.12, "Vibration": 0.95, "Speaker": 0.78, "Heart rate": 0.02, "Bluetooth": 0.58, "CPU": 0.40 };
        var hue = (cat in hues) ? hues[cat] : ((i * 0.16) % 1.0);
        var dark = Kirigami.Theme.backgroundColor.hslLightness < 0.5;
        return Qt.hsla(hue, 0.55, dark ? 0.62 : 0.46, 1.0);
    }

    Connections {
        target: StoandlClient
        function onWatchesChanged(rows) { page.reload(); }          // battery change pokes WatchesChanged
        function onDaemonUpChanged() { if (StoandlClient.daemonUp) page.reload(); }
    }
    Component.onCompleted: page.reload()

    header: QQC2.ToolBar {
        visible: StoandlClient.daemonUp && page.hasInsights
        height: visible ? implicitHeight : 0
        position: QQC2.ToolBar.Header
        contentItem: RowLayout {
            spacing: Kirigami.Units.smallSpacing
            Repeater {
                model: [[24 * 3600, "24 h"], [7 * 86400, "7 days"], [30 * 86400, "30 days"]]
                delegate: QQC2.Button {
                    required property var modelData
                    Layout.fillWidth: true
                    text: modelData[1]
                    checkable: true
                    autoExclusive: true
                    checked: page.rangeSeconds === modelData[0]
                    onClicked: page.setRange(modelData[0])
                }
            }
        }
    }

    // --- empty states ------------------------------------------------------
    Kirigami.PlaceholderMessage {
        anchors.centerIn: parent
        width: parent.width - Kirigami.Units.gridUnit * 4
        visible: !page.hasInsights
        icon.name: page.insights && page.insights.kind === "notready" ? "battery-missing-symbolic" : "battery-symbolic"
        text: !StoandlClient.daemonUp ? "Daemon not running"
              : (page.insights && page.insights.kind === "notready") ? "No battery data"
              : "No battery data yet"
        explanation: !StoandlClient.daemonUp ? "Start it with: systemctl --user start stoandl"
              : (page.insights && page.insights.kind === "notready") ? "Battery capture is off, or no watch is connected."
              : "Insights build up as the watch reports. The analytics heartbeat arrives about once an hour."
    }

    ColumnLayout {
        visible: page.hasInsights
        spacing: Kirigami.Units.largeSpacing

        // ── Hero: current level + gauge + charging/voltage/time-left ───────
        FormCard.FormCard {
            Layout.fillWidth: true
            FormCard.AbstractFormDelegate {
                background: null
                contentItem: ColumnLayout {
                    spacing: Kirigami.Units.largeSpacing

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.largeSpacing

                        Kirigami.Heading {
                            level: 1
                            text: page.level + "%"
                            color: page.levelColor(page.level, page.charging)
                            font.pointSize: Kirigami.Theme.defaultFont.pointSize * 2.4
                        }
                        Kirigami.Icon {
                            source: "battery-full-charging-symbolic"
                            visible: page.charging
                            color: Kirigami.Theme.positiveTextColor
                            implicitWidth: Kirigami.Units.iconSizes.medium
                            implicitHeight: Kirigami.Units.iconSizes.medium
                        }
                        Item { Layout.fillWidth: true }
                        StatusChip {
                            label: page.charging ? "Charging" : (page.level >= 98 ? "Full" : "Discharging")
                            tint: page.charging ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.disabledTextColor
                        }
                    }

                    // horizontal battery gauge
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Kirigami.Units.gridUnit
                        radius: height / 4
                        color: "transparent"
                        border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.25)
                        border.width: 1
                        Rectangle {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            anchors.margins: 2
                            width: Math.max(radius * 2, (parent.width - 4) * Math.min(1, Math.max(0, page.level / 100)))
                            radius: parent.radius
                            color: page.levelColor(page.level, page.charging)
                            Behavior on width { NumberAnimation { duration: Kirigami.Units.longDuration } }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.gridUnit * 2
                        StatTile {
                            visible: page.hasInsights && String(page.insights.voltage) !== ""
                            value: page.hasInsights ? (String(page.insights.voltage) + " V") : ""
                            label: "voltage"
                        }
                        StatTile {
                            visible: !page.charging && page.hasInsights && String(page.insights.hoursRemaining) !== ""
                            value: "~" + String(page.hasInsights ? page.insights.hoursRemaining : "") + " h"
                            label: "time remaining"
                        }
                        Item { Layout.fillWidth: true }
                    }
                }
            }
        }

        // ── Chart: battery % over the selected window ──────────────────────
        FormCard.FormHeader { title: "Over the last " + (page.rangeSeconds === 24 * 3600 ? "24 hours" : (page.rangeSeconds / 86400) + " days") }
        FormCard.FormCard {
            Layout.fillWidth: true
            FormCard.AbstractFormDelegate {
                background: null
                contentItem: ColumnLayout {
                    spacing: Kirigami.Units.smallSpacing

                    Kirigami.PlaceholderMessage {
                        Layout.fillWidth: true
                        visible: page.history.length < 2
                        icon.name: "office-chart-line"
                        text: "Not enough samples yet"
                        explanation: "The chart fills in as readings arrive."
                    }

                    RowLayout {
                        visible: page.history.length >= 2
                        Layout.fillWidth: true
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 11
                        spacing: Kirigami.Units.smallSpacing

                        // y-axis gutter: 100 / 50 / 0 %
                        ColumnLayout {
                            Layout.fillHeight: true
                            spacing: 0
                            QQC2.Label { text: "100%"; font: Kirigami.Theme.smallFont; opacity: 0.5 }
                            Item { Layout.fillHeight: true }
                            QQC2.Label { text: "50%"; font: Kirigami.Theme.smallFont; opacity: 0.5 }
                            Item { Layout.fillHeight: true }
                            QQC2.Label { text: "0%"; font: Kirigami.Theme.smallFont; opacity: 0.5 }
                        }

                        Canvas {
                            id: chart
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            onWidthChanged: requestPaint()
                            onHeightChanged: requestPaint()
                            onPaint: {
                                var ctx = getContext("2d");
                                ctx.reset();
                                var w = width, h = height, pad = 4;
                                function py(lv) { return h - (lv / 100) * (h - 2 * pad) - pad; }
                                var tc = Kirigami.Theme.textColor;
                                // gridlines at 0/25/50/75/100 %
                                ctx.strokeStyle = Qt.rgba(tc.r, tc.g, tc.b, 0.12);
                                ctx.lineWidth = 1;
                                for (var g = 0; g <= 100; g += 25) {
                                    var gy = py(g);
                                    ctx.beginPath(); ctx.moveTo(0, gy); ctx.lineTo(w, gy); ctx.stroke();
                                }
                                // notification-density hint: faint full-height bands where notifications
                                // arrived, denser hours more visible — drawn behind the line/area.
                                var acts = page.activity;
                                if (acts && acts.length) {
                                    var t0n = page.rangeStart, spann = (page.nowSec - t0n) || 1;
                                    var maxN = 0;
                                    for (var j = 0; j < acts.length; ++j) maxN = Math.max(maxN, acts[j].notif);
                                    if (maxN > 0) {
                                        var nc = Kirigami.Theme.highlightColor;
                                        var bw = Math.max(2, Math.min(24, (w / (spann / 3600)) * 0.7));
                                        for (j = 0; j < acts.length; ++j) {
                                            if (acts[j].notif <= 0) continue;
                                            var alpha = 0.06 + 0.20 * (acts[j].notif / maxN);
                                            var bx = Math.max(0, Math.min(w, ((acts[j].ts - t0n) / spann) * w)) - bw / 2;
                                            ctx.fillStyle = Qt.rgba(nc.r, nc.g, nc.b, alpha);
                                            ctx.fillRect(bx, 0, bw, h);
                                        }
                                    }
                                }
                                var data = page.history;
                                if (!data || data.length < 1) return;
                                var t0 = page.rangeStart, span = (page.nowSec - t0) || 1;
                                function px(ts) { return Math.max(0, Math.min(w, ((ts - t0) / span) * w)); }
                                var accent = Kirigami.Theme.highlightColor;
                                var n = data.length;
                                if (n === 1) {
                                    ctx.beginPath(); ctx.arc(px(data[0].ts), py(data[0].level), 3, 0, 2 * Math.PI);
                                    ctx.fillStyle = accent; ctx.fill(); return;
                                }
                                // area fill under the curve
                                ctx.beginPath();
                                ctx.moveTo(px(data[0].ts), py(data[0].level));
                                for (var i = 1; i < n; ++i) ctx.lineTo(px(data[i].ts), py(data[i].level));
                                ctx.lineTo(px(data[n - 1].ts), h);
                                ctx.lineTo(px(data[0].ts), h);
                                ctx.closePath();
                                var grad = ctx.createLinearGradient(0, 0, 0, h);
                                grad.addColorStop(0, Qt.rgba(accent.r, accent.g, accent.b, 0.30));
                                grad.addColorStop(1, Qt.rgba(accent.r, accent.g, accent.b, 0.0));
                                ctx.fillStyle = grad; ctx.fill();
                                // the line
                                ctx.beginPath();
                                ctx.moveTo(px(data[0].ts), py(data[0].level));
                                for (i = 1; i < n; ++i) ctx.lineTo(px(data[i].ts), py(data[i].level));
                                ctx.lineWidth = 2; ctx.lineJoin = "round"; ctx.strokeStyle = accent; ctx.stroke();
                            }
                            Connections { target: page; function onHistoryChanged() { chart.requestPaint(); } function onActivityChanged() { chart.requestPaint(); } }
                            Connections { target: Kirigami.Theme; function onColorsChanged() { chart.requestPaint(); } }
                        }
                    }

                    // x-axis time labels (start · mid · now)
                    Item {
                        visible: page.history.length >= 2
                        Layout.fillWidth: true
                        Layout.leftMargin: Kirigami.Units.gridUnit * 2
                        Layout.preferredHeight: Kirigami.Units.gridUnit
                        Repeater {
                            model: page.axisTicks
                            delegate: QQC2.Label {
                                required property var modelData
                                text: modelData.text
                                font: Kirigami.Theme.smallFont
                                opacity: 0.5
                                x: Math.max(0, Math.min(parent.width - width, modelData.frac * parent.width - width / 2))
                            }
                        }
                    }
                }
            }
        }

        // caption for the notification-density overlay on the % chart above
        QQC2.Label {
            visible: page.hasNotifs
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.gridUnit
            text: "Shaded bands mark hours with notifications — denser bands, more notifications."
            font: Kirigami.Theme.smallFont
            opacity: 0.6
            wrapMode: Text.WordWrap
        }

        // ── Chart: battery drain per interval (bars, aligned to the line chart above) ──────
        FormCard.FormHeader { title: "Battery drain" }
        FormCard.FormCard {
            Layout.fillWidth: true
            FormCard.AbstractFormDelegate {
                background: null
                contentItem: ColumnLayout {
                    spacing: Kirigami.Units.smallSpacing

                    Kirigami.PlaceholderMessage {
                        Layout.fillWidth: true
                        visible: page.activity.length < 1
                        icon.name: "office-chart-bar"
                        text: "No drain data yet"
                        explanation: "Each bar is the battery used in one hourly analytics heartbeat."
                    }

                    RowLayout {
                        visible: page.activity.length >= 1
                        Layout.fillWidth: true
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 7
                        spacing: Kirigami.Units.smallSpacing

                        // y-axis gutter: peak drain / 0
                        ColumnLayout {
                            Layout.fillHeight: true
                            spacing: 0
                            QQC2.Label { text: (page.maxDrop > 0 ? page.maxDrop.toFixed(1) : "0") + "%"; font: Kirigami.Theme.smallFont; opacity: 0.5 }
                            Item { Layout.fillHeight: true }
                            QQC2.Label { text: "0%"; font: Kirigami.Theme.smallFont; opacity: 0.5 }
                        }

                        Canvas {
                            id: dropChart
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            onWidthChanged: requestPaint()
                            onHeightChanged: requestPaint()
                            onPaint: {
                                var ctx = getContext("2d");
                                ctx.reset();
                                var w = width, h = height, pad = 4;
                                var tc = Kirigami.Theme.textColor;
                                // baseline
                                ctx.strokeStyle = Qt.rgba(tc.r, tc.g, tc.b, 0.12); ctx.lineWidth = 1;
                                ctx.beginPath(); ctx.moveTo(0, h - pad); ctx.lineTo(w, h - pad); ctx.stroke();
                                var data = page.activity;
                                if (!data || data.length < 1) return;
                                var t0 = page.rangeStart, span = (page.nowSec - t0) || 1;
                                var maxD = page.maxDrop > 0 ? page.maxDrop : 1;
                                function px(ts) { return ((ts - t0) / span) * w; }
                                // one heartbeat ≈ 1 h wide; clamp so bars stay visible on long ranges
                                var barW = Math.max(2, Math.min(28, (w / (span / 3600)) * 0.7));
                                var col = Kirigami.Theme.neutralTextColor;
                                ctx.fillStyle = Qt.rgba(col.r, col.g, col.b, 0.75);
                                for (var i = 0; i < data.length; ++i) {
                                    var d = data[i];
                                    if (d.drop <= 0) continue;
                                    var bh = (d.drop / maxD) * (h - 2 * pad);
                                    ctx.fillRect(px(d.ts) - barW / 2, h - pad - bh, barW, bh);
                                }
                            }
                            Connections { target: page; function onActivityChanged() { dropChart.requestPaint(); } }
                            Connections { target: Kirigami.Theme; function onColorsChanged() { dropChart.requestPaint(); } }
                        }
                    }

                    // x-axis time labels (same window as the % chart)
                    Item {
                        visible: page.activity.length >= 1
                        Layout.fillWidth: true
                        Layout.leftMargin: Kirigami.Units.gridUnit * 2
                        Layout.preferredHeight: Kirigami.Units.gridUnit
                        Repeater {
                            model: page.axisTicks
                            delegate: QQC2.Label {
                                required property var modelData
                                text: modelData.text
                                font: Kirigami.Theme.smallFont
                                opacity: 0.5
                                x: Math.max(0, Math.min(parent.width - width, modelData.frac * parent.width - width / 2))
                            }
                        }
                    }
                }
            }
        }

        // ── Pie: what drew power (estimated usage share) ───────────────────
        FormCard.FormHeader { title: "What drew power" }
        FormCard.FormCard {
            Layout.fillWidth: true
            FormCard.AbstractFormDelegate {
                background: null
                contentItem: ColumnLayout {
                    spacing: Kirigami.Units.largeSpacing

                    Kirigami.PlaceholderMessage {
                        Layout.fillWidth: true
                        visible: page.power.length < 1
                        icon.name: "office-chart-pie"
                        text: "No usage breakdown yet"
                        explanation: "Built from the hourly analytics heartbeat (Bluetooth LE watches)."
                    }

                    RowLayout {
                        visible: page.power.length >= 1
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.largeSpacing

                        // donut
                        Canvas {
                            id: powerPie
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                            Layout.preferredHeight: Kirigami.Units.gridUnit * 8
                            Layout.alignment: Qt.AlignTop
                            onWidthChanged: requestPaint()
                            onHeightChanged: requestPaint()
                            onPaint: {
                                var ctx = getContext("2d");
                                ctx.reset();
                                var data = page.power;
                                if (!data || data.length < 1) return;
                                var total = 0;
                                for (var k = 0; k < data.length; ++k) total += data[k].share;
                                if (total <= 0) return;
                                var w = width, h = height;
                                var cx = w / 2, cy = h / 2, r = Math.min(w, h) / 2 - 2, rin = r * 0.58;
                                var a0 = -Math.PI / 2;
                                for (var i = 0; i < data.length; ++i) {
                                    var a1 = a0 + (data[i].share / total) * 2 * Math.PI;
                                    ctx.beginPath();
                                    ctx.moveTo(cx, cy);
                                    ctx.arc(cx, cy, r, a0, a1);
                                    ctx.closePath();
                                    ctx.fillStyle = data[i].color;
                                    ctx.fill();
                                    a0 = a1;
                                }
                                // punch a transparent hole → donut (no dependence on the card bg colour)
                                ctx.globalCompositeOperation = "destination-out";
                                ctx.beginPath(); ctx.arc(cx, cy, rin, 0, 2 * Math.PI); ctx.fill();
                                ctx.globalCompositeOperation = "source-over";
                            }
                            Connections { target: page; function onPowerChanged() { powerPie.requestPaint(); } }
                        }

                        // legend: swatch · category · share%
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            spacing: Kirigami.Units.smallSpacing
                            Repeater {
                                model: page.power
                                delegate: RowLayout {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing
                                    Rectangle {
                                        implicitWidth: Kirigami.Units.gridUnit * 0.8
                                        implicitHeight: Kirigami.Units.gridUnit * 0.8
                                        radius: 2
                                        color: parent.modelData.color
                                    }
                                    QQC2.Label {
                                        Layout.fillWidth: true
                                        text: parent.modelData.category
                                        elide: Text.ElideRight
                                    }
                                    QQC2.Label {
                                        text: parent.modelData.share.toFixed(0) + "%"
                                        font.bold: true
                                        opacity: 0.9
                                    }
                                }
                            }
                        }
                    }

                    QQC2.Label {
                        visible: page.power.length >= 1 && page.powerDrainTotal > 0
                        Layout.fillWidth: true
                        text: "≈ " + page.powerDrainTotal.toFixed(1) + "% battery over this window"
                        opacity: 0.9
                    }

                    QQC2.Label {
                        visible: page.power.length >= 1
                        Layout.fillWidth: true
                        text: "Estimated share of battery drain (modeled current × on-time), anchored to the watch’s measured SoC drop — not metered energy. “Display” is the backlight; “System” is the always-on floor."
                        font: Kirigami.Theme.smallFont
                        opacity: 0.6
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }

        // ── Headline stats ────────────────────────────────────────────────
        FormCard.FormHeader { title: "Trends" }
        FormCard.FormCard {
            Layout.fillWidth: true
            FormCard.AbstractFormDelegate {
                background: null
                contentItem: GridLayout {
                    columns: 2
                    columnSpacing: Kirigami.Units.gridUnit * 2
                    rowSpacing: Kirigami.Units.largeSpacing
                    StatTile {
                        Layout.fillWidth: true
                        value: page.charging ? "—" : ((page.hasInsights ? page.insights.dischargePerHour.toFixed(1) : "0") + " %/h")
                        label: "discharge rate"
                    }
                    StatTile {
                        Layout.fillWidth: true
                        value: page.hasInsights ? String(page.insights.chargeSessions) : "0"
                        label: "charges · 7 days"
                    }
                    StatTile {
                        Layout.fillWidth: true
                        value: page.hasInsights ? page.relAge(page.insights.lastChargedEpoch) : "—"
                        label: "last charged"
                    }
                    StatTile {
                        Layout.fillWidth: true
                        value: page.hasInsights ? (Math.round(page.insights.min24h) + "–" + Math.round(page.insights.max24h) + "%") : "—"
                        label: "range · 24 h"
                    }
                }
            }
        }

        // ── Source footnote ────────────────────────────────────────────────
        QQC2.Label {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.gridUnit
            Layout.topMargin: Kirigami.Units.smallSpacing
            visible: page.hasInsights
            text: page.hasInsights ? (page.sourceLabel(page.insights.source) + " · " + page.insights.sampleCount + " samples") : ""
            font: Kirigami.Theme.smallFont
            opacity: 0.6
            wrapMode: Text.WordWrap
        }
    }

    // value-over-label stat tile (matches HealthPage's StatTile density)
    component StatTile: ColumnLayout {
        property string value
        property string label
        spacing: 0
        QQC2.Label {
            text: parent.value
            font.bold: true
            font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.1
            elide: Text.ElideRight
        }
        QQC2.Label {
            text: parent.label
            font: Kirigami.Theme.smallFont
            opacity: 0.7
        }
    }
}
