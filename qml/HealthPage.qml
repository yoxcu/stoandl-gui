import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// Read-only health dashboard (prototype: HealthScreen). Every value is polled in
// C++ via healthSummary()/healthSeries(); QML only renders. No mutation here except
// the explicit "Sync health" page action (syncHealth() -> reload()).
Kirigami.ScrollablePage {
    id: page
    objectName: "health"
    title: "Health"

    // Latest snapshots (parsed in C++). summary.kind !== "ok" => no data yet.
    property var summary: ({})
    property var stepSeries: []
    property var sleepSeries: []
    property var heartSeries: []

    readonly property bool hasData: summary && summary.kind === "ok"
    readonly property bool hrAvailable: hasData && summary.hrAvailable === true

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    function reload() {
        if (!StoandlClient.daemonUp) {
            page.summary = ({});
            page.stepSeries = [];
            page.sleepSeries = [];
            page.heartSeries = [];
            return;
        }
        page.summary = StoandlClient.healthSummary();
        page.stepSeries = StoandlClient.healthSeries("steps");
        page.sleepSeries = StoandlClient.healthSeries("sleep");
        page.heartSeries = page.hrAvailable ? StoandlClient.healthSeries("heart") : [];
    }

    function syncHealth() {
        var r = StoandlClient.syncHealth();
        if (r.ok)
            page.toast("Syncing health data…");
        else if (r.kind === "notready")
            page.toast("No watch connected");
        else if (r.tail.toLowerCase().indexOf("not enabled") !== -1)
            // The daemon signals "disabled in config" via error:…not enabled (no `disabled` kind here).
            page.toast("Health sync is disabled — enable it in Settings");
        else
            page.toast("Health: " + (r.tail !== "" ? r.tail : r.kind));
        page.reload();
    }

    // minutes -> "Hh MMm"
    function fmtMin(m) {
        var mm = String(m % 60);
        if (mm.length < 2) mm = "0" + mm;
        return Math.floor(m / 60) + "h " + mm + "m";
    }

    // Index of the most recent day that has a value (prototype's todayIndex).
    function todayIndexOf(series) {
        var idx = -1;
        for (var i = 0; i < series.length; ++i)
            if (series[i] && series[i].hasValue) idx = i;
        return idx;
    }

    Connections {
        target: StoandlClient
        function onDaemonUpChanged() { if (StoandlClient.daemonUp) page.reload(); }
    }

    Component.onCompleted: page.reload()

    // No primary "add". One secondary refresh action.
    actions: [
        Kirigami.Action {
            icon.name: "view-refresh-symbolic"
            text: "Sync health"
            enabled: StoandlClient.daemonUp
            onTriggered: page.syncHealth()
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

        // --- no-data empty state -------------------------------------------
        Kirigami.PlaceholderMessage {
            visible: StoandlClient.daemonUp && !page.hasData
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
            icon.name: "heart-symbolic"
            text: "No health data yet"
            explanation: "Sync your watch to pull steps, sleep, and heart-rate history. "
                       + "Health tracking must be enabled in Settings."
            helpfulAction: Kirigami.Action {
                icon.name: "view-refresh-symbolic"
                text: "Sync health"
                onTriggered: page.syncHealth()
            }
        }

        // ============ TODAY ============
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp && page.hasData
            title: "Today"
        }

        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.hasData

            FormCard.AbstractFormDelegate {
                background: null
                Layout.fillWidth: true

                contentItem: ColumnLayout {
                    spacing: Kirigami.Units.largeSpacing

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.largeSpacing

                        // Step-goal ring.
                        Item {
                            id: ringBox
                            implicitWidth: Kirigami.Units.gridUnit * 5
                            implicitHeight: Kirigami.Units.gridUnit * 5
                            Layout.alignment: Qt.AlignVCenter

                            readonly property int pct: {
                                var goal = page.hasData ? (page.summary.stepGoal || 0) : 0;
                                if (goal <= 0) return 0;
                                return Math.round((page.summary.steps || 0) / goal * 100);
                            }

                            Canvas {
                                id: ringCanvas
                                anchors.fill: parent
                                onPaint: {
                                    var ctx = getContext("2d");
                                    ctx.reset();
                                    var w = width, h = height;
                                    var stroke = Math.max(4, w * 0.1);
                                    var r = (Math.min(w, h) - stroke) / 2;
                                    var cx = w / 2, cy = h / 2;
                                    // Background circle.
                                    ctx.beginPath();
                                    ctx.arc(cx, cy, r, 0, 2 * Math.PI);
                                    ctx.lineWidth = stroke;
                                    var bg = Kirigami.Theme.textColor;
                                    ctx.strokeStyle = Qt.rgba(bg.r, bg.g, bg.b, 0.12);
                                    ctx.stroke();
                                    // Accent arc.
                                    var frac = Math.min(1, ringBox.pct / 100);
                                    if (frac > 0) {
                                        ctx.beginPath();
                                        ctx.arc(cx, cy, r, -Math.PI / 2,
                                                -Math.PI / 2 + frac * 2 * Math.PI);
                                        ctx.lineWidth = stroke;
                                        ctx.lineCap = "round";
                                        ctx.strokeStyle = Kirigami.Theme.highlightColor;
                                        ctx.stroke();
                                    }
                                }
                                Connections {
                                    target: page
                                    function onSummaryChanged() { ringCanvas.requestPaint(); }
                                }
                                Connections {
                                    target: Kirigami.Theme
                                    function onColorsChanged() { ringCanvas.requestPaint(); }
                                }
                            }

                            QQC2.Label {
                                anchors.centerIn: parent
                                text: ringBox.pct + "%"
                                font.bold: true
                                font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.2
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Kirigami.Heading {
                                level: 1
                                text: page.hasData ? String(page.summary.steps) : "—"
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: "of " + (page.hasData ? page.summary.stepGoal : "—") + " steps today"
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                                elide: Text.ElideRight
                            }
                        }
                    }

                    Kirigami.Separator { Layout.fillWidth: true }

                    // Three tiles.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.largeSpacing

                        StatTile {
                            Layout.fillWidth: true
                            value: (page.hasData ? page.summary.distanceKm : "—") + " km"
                            label: "Distance"
                        }
                        StatTile {
                            Layout.fillWidth: true
                            value: page.hasData ? String(page.summary.kcal) : "—"
                            label: "Calories"
                        }
                        StatTile {
                            Layout.fillWidth: true
                            value: (page.hasData ? page.summary.activeMin : "—") + " min"
                            label: "Active"
                        }
                    }
                }
            }
        }

        // ============ STEPS · THIS WEEK ============
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp && page.hasData
            title: "Steps · this week"
        }

        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.hasData

            FormCard.AbstractFormDelegate {
                background: null
                Layout.fillWidth: true

                contentItem: ColumnLayout {
                    spacing: Kirigami.Units.largeSpacing

                    readonly property int todayIdx: page.todayIndexOf(page.stepSeries)
                    readonly property int maxVal: {
                        var m = page.hasData ? (page.summary.stepGoal || 0) : 0;
                        for (var i = 0; i < page.stepSeries.length; ++i) {
                            var v = page.stepSeries[i];
                            if (v && v.hasValue && v.value > m) m = v.value;
                        }
                        return Math.max(1, Math.round(m * 1.14));
                    }

                    // Bars.
                    RowLayout {
                        id: stepBars
                        Layout.fillWidth: true
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 6
                        spacing: Kirigami.Units.smallSpacing

                        Repeater {
                            model: page.stepSeries
                            delegate: ColumnLayout {
                                required property var modelData
                                required property int index
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                spacing: 0

                                Item { Layout.fillWidth: true; Layout.fillHeight: true }

                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: {
                                        if (!parent.modelData.hasValue) return 0;
                                        var frac = parent.modelData.value / stepBars.parent.maxVal;
                                        return Math.max(Kirigami.Units.smallSpacing / 2,
                                                        frac * stepBars.height);
                                    }
                                    radius: Kirigami.Units.smallSpacing / 2
                                    color: {
                                        var hl = Kirigami.Theme.highlightColor;
                                        if (!parent.modelData.hasValue)
                                            return Qt.rgba(Kirigami.Theme.textColor.r,
                                                           Kirigami.Theme.textColor.g,
                                                           Kirigami.Theme.textColor.b, 0.07);
                                        if (parent.index === stepBars.parent.todayIdx)
                                            return hl;
                                        return Qt.rgba(hl.r, hl.g, hl.b, 0.4);
                                    }
                                }
                            }
                        }
                    }

                    // Day labels.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Repeater {
                            model: page.stepSeries
                            delegate: QQC2.Label {
                                required property var modelData
                                required property int index
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: modelData.label
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                font.bold: index === stepBars.parent.todayIdx
                                opacity: index === stepBars.parent.todayIdx ? 1.0 : 0.6
                            }
                        }
                    }

                    Kirigami.Separator { Layout.fillWidth: true }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.largeSpacing
                        QQC2.Label {
                            text: "Daily avg "
                            opacity: 0.7
                        }
                        QQC2.Label {
                            text: page.hasData ? String(page.summary.stepWeekAvg) : "—"
                            font.bold: true
                        }
                        Item { Layout.fillWidth: true }
                        TrendChip { pct: page.hasData ? page.summary.stepTrendPct : 0 }
                        QQC2.Label { text: "vs last week"; opacity: 0.7; font: Kirigami.Theme.smallFont }
                    }
                }
            }
        }

        // ============ SLEEP · LAST NIGHT ============
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp && page.hasData
            title: "Sleep · last night"
        }

        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.hasData

            FormCard.AbstractFormDelegate {
                background: null
                Layout.fillWidth: true

                contentItem: ColumnLayout {
                    spacing: Kirigami.Units.largeSpacing

                    readonly property int deepMin: page.hasData ? (page.summary.sleepDeepMin || 0) : 0
                    readonly property int lightMin: page.hasData ? (page.summary.sleepLightMin || 0) : 0
                    readonly property int remMin: page.hasData ? (page.summary.sleepRemMin || 0) : 0
                    readonly property int totalMin: page.hasData ? (page.summary.sleepTotalMin || 0) : 0

                    // Three distinct theme-derived tints for the stages.
                    readonly property color deepTint: Kirigami.Theme.highlightColor
                    readonly property color lightTint: Kirigami.Theme.positiveTextColor
                    readonly property color remTint: Kirigami.Theme.neutralTextColor

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Kirigami.Heading {
                            level: 1
                            text: page.hasData ? page.fmtMin(parent.totalMin) : "—"
                        }
                        QQC2.Label {
                            text: "asleep"
                            opacity: 0.7
                            Layout.alignment: Qt.AlignBaseline
                        }
                    }

                    // Stacked horizontal bar.
                    RowLayout {
                        id: sleepBar
                        Layout.fillWidth: true
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 0.75
                        spacing: Kirigami.Units.smallSpacing / 2

                        Rectangle {
                            Layout.fillHeight: true
                            Layout.preferredWidth: 1
                            Layout.fillWidth: sleepBar.parent.deepMin > 0
                            Layout.horizontalStretchFactor: Math.max(0, sleepBar.parent.deepMin)
                            visible: sleepBar.parent.deepMin > 0
                            radius: height / 4
                            color: sleepBar.parent.deepTint
                        }
                        Rectangle {
                            Layout.fillHeight: true
                            Layout.preferredWidth: 1
                            Layout.fillWidth: sleepBar.parent.lightMin > 0
                            Layout.horizontalStretchFactor: Math.max(0, sleepBar.parent.lightMin)
                            visible: sleepBar.parent.lightMin > 0
                            radius: height / 4
                            color: sleepBar.parent.lightTint
                        }
                        Rectangle {
                            Layout.fillHeight: true
                            Layout.preferredWidth: 1
                            Layout.fillWidth: sleepBar.parent.remMin > 0
                            Layout.horizontalStretchFactor: Math.max(0, sleepBar.parent.remMin)
                            visible: sleepBar.parent.remMin > 0
                            radius: height / 4
                            color: sleepBar.parent.remTint
                        }
                    }

                    // Legend.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.largeSpacing
                        SleepLegend { tint: sleepBar.parent.deepTint; name: "Deep"; mins: page.fmtMin(sleepBar.parent.deepMin) }
                        SleepLegend { tint: sleepBar.parent.lightTint; name: "Light"; mins: page.fmtMin(sleepBar.parent.lightMin) }
                        SleepLegend { tint: sleepBar.parent.remTint; name: "REM"; mins: page.fmtMin(sleepBar.parent.remMin) }
                        Item { Layout.fillWidth: true }
                    }

                    Kirigami.Separator { Layout.fillWidth: true }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.largeSpacing
                        QQC2.Label { text: "Weekly avg "; opacity: 0.7 }
                        QQC2.Label {
                            text: page.hasData ? page.fmtMin(page.summary.sleepAvgMin || 0) : "—"
                            font.bold: true
                        }
                        Item { Layout.fillWidth: true }
                        TrendChip { pct: page.hasData ? page.summary.sleepTrendPct : 0 }
                        QQC2.Label { text: "vs last week"; opacity: 0.7; font: Kirigami.Theme.smallFont }
                    }
                }
            }
        }

        // ============ HEART RATE (only when available) ============
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp && page.hrAvailable
            title: "Heart rate"
        }

        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.hrAvailable

            FormCard.AbstractFormDelegate {
                background: null
                Layout.fillWidth: true

                contentItem: ColumnLayout {
                    spacing: Kirigami.Units.largeSpacing

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.gridUnit

                        ColumnLayout {
                            spacing: 0
                            RowLayout {
                                spacing: Kirigami.Units.smallSpacing / 2
                                Kirigami.Heading {
                                    level: 1
                                    text: page.hrAvailable ? String(page.summary.restingHr) : "—"
                                    color: Kirigami.Theme.negativeTextColor
                                }
                                QQC2.Label { text: "bpm"; opacity: 0.7; Layout.alignment: Qt.AlignBaseline }
                            }
                            QQC2.Label { text: "Resting"; font: Kirigami.Theme.smallFont; opacity: 0.7 }
                        }

                        ColumnLayout {
                            spacing: 0
                            RowLayout {
                                spacing: Kirigami.Units.smallSpacing / 2
                                Kirigami.Heading {
                                    level: 3
                                    text: page.hrAvailable ? String(page.summary.currentHr) : "—"
                                }
                                QQC2.Label { text: "bpm"; opacity: 0.7; Layout.alignment: Qt.AlignBaseline }
                            }
                            QQC2.Label { text: "Now"; font: Kirigami.Theme.smallFont; opacity: 0.7 }
                        }

                        Item { Layout.fillWidth: true }
                    }

                    // 24h area sparkline.
                    Canvas {
                        id: hrCanvas
                        Layout.fillWidth: true
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 3

                        onPaint: {
                            var ctx = getContext("2d");
                            ctx.reset();
                            var data = page.heartSeries;
                            if (!data || data.length < 2) return;

                            var lo = Number.POSITIVE_INFINITY, hi = Number.NEGATIVE_INFINITY;
                            for (var i = 0; i < data.length; ++i) {
                                var v = data[i].value;
                                if (v < lo) lo = v;
                                if (v > hi) hi = v;
                            }
                            var span = (hi - lo) || 1;
                            var w = width, h = height;
                            var pad = 3;
                            var n = data.length;

                            function px(i) { return (i / (n - 1)) * w; }
                            function py(v) { return h - ((v - lo) / span) * (h - 2 * pad) - pad; }

                            var hr = Kirigami.Theme.negativeTextColor;

                            // Area fill (gradient -> transparent).
                            ctx.beginPath();
                            ctx.moveTo(px(0), py(data[0].value));
                            for (i = 1; i < n; ++i) ctx.lineTo(px(i), py(data[i].value));
                            ctx.lineTo(px(n - 1), h);
                            ctx.lineTo(px(0), h);
                            ctx.closePath();
                            var grad = ctx.createLinearGradient(0, 0, 0, h);
                            grad.addColorStop(0, Qt.rgba(hr.r, hr.g, hr.b, 0.35));
                            grad.addColorStop(1, Qt.rgba(hr.r, hr.g, hr.b, 0.0));
                            ctx.fillStyle = grad;
                            ctx.fill();

                            // Line.
                            ctx.beginPath();
                            ctx.moveTo(px(0), py(data[0].value));
                            for (i = 1; i < n; ++i) ctx.lineTo(px(i), py(data[i].value));
                            ctx.lineWidth = 2;
                            ctx.lineJoin = "round";
                            ctx.strokeStyle = hr;
                            ctx.stroke();
                        }

                        Connections {
                            target: page
                            function onHeartSeriesChanged() { hrCanvas.requestPaint(); }
                        }
                        Connections {
                            target: Kirigami.Theme
                            function onColorsChanged() { hrCanvas.requestPaint(); }
                        }
                    }

                    QQC2.Label {
                        Layout.fillWidth: true
                        text: page.hrAvailable
                              ? ("24h · min " + page.summary.hrMin + "   max " + page.summary.hrMax + " bpm")
                              : ""
                        font: Kirigami.Theme.smallFont
                        opacity: 0.6
                    }
                }
            }
        }
    }

    // --- a stat tile (value over label, centered) --------------------------
    component StatTile: ColumnLayout {
        property string value
        property string label
        spacing: 0
        QQC2.Label {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: parent.value
            font.bold: true
            font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.1
            elide: Text.ElideRight
        }
        QQC2.Label {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: parent.label
            font: Kirigami.Theme.smallFont
            opacity: 0.7
        }
    }

    // --- a trend chip ("↑ 8%" green up / "↓ 4%" amber down) ----------------
    component TrendChip: RowLayout {
        property int pct: 0
        readonly property bool up: pct >= 0
        spacing: Kirigami.Units.smallSpacing / 2
        QQC2.Label {
            text: parent.up ? "↑" : "↓"
            color: parent.up ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.neutralTextColor
            font.bold: true
        }
        QQC2.Label {
            text: Math.abs(parent.pct) + "%"
            color: parent.up ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.neutralTextColor
            font.bold: true
        }
    }

    // --- a sleep-stage legend entry (swatch + "Name 1h 48m") ---------------
    component SleepLegend: RowLayout {
        property color tint
        property string name
        property string mins
        spacing: Kirigami.Units.smallSpacing
        Rectangle {
            implicitWidth: Kirigami.Units.smallSpacing
            implicitHeight: Kirigami.Units.smallSpacing
            radius: 2
            color: parent.tint
            Layout.alignment: Qt.AlignVCenter
        }
        QQC2.Label {
            text: parent.name
            font: Kirigami.Theme.smallFont
            opacity: 0.7
        }
        QQC2.Label {
            text: parent.mins
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            font.bold: true
        }
    }
}
