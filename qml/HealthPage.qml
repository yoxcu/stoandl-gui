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
    property var sleepSegments: []   // last night's light/deep timeline (fractions of a 6 PM→noon window)
    property var heartSeries: []     // minute-level samples for the shown day: [{minute(0-1439),bpm}]

    // Which day the heart-rate chart shows: 0 = today, 1 = yesterday, … up to hrMaxLookback.
    property int hrDayOffset: 0
    readonly property int hrMaxLookback: 6   // browse the last 7 days

    readonly property bool hasData: summary && summary.kind === "ok"
    readonly property bool hrAvailable: hasData && summary.hrAvailable === true

    // min / max / avg / count derived from the shown day's samples (so every day — not just today —
    // gets correct figures; the summary's hr fields are today-only).
    readonly property var hrStats: {
        var arr = page.heartSeries;
        if (!arr || arr.length === 0) return { count: 0, min: 0, max: 0, avg: 0 };
        var lo = 1e9, hi = -1e9, sum = 0;
        for (var i = 0; i < arr.length; ++i) {
            var b = arr[i].bpm;
            if (b < lo) lo = b;
            if (b > hi) hi = b;
            sum += b;
        }
        return { count: arr.length, min: lo, max: hi, avg: Math.round(sum / arr.length) };
    }

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    // 0 → "Today", 1 → "Yesterday", else the date of today − offset.
    function hrDayLabel(offset) {
        if (offset === 0) return "Today";
        if (offset === 1) return "Yesterday";
        var d = new Date();
        d.setDate(d.getDate() - offset);
        return d.toLocaleDateString(Qt.locale(), "ddd d MMM");
    }

    function reloadHeart() {
        page.heartSeries = page.hrAvailable ? StoandlClient.heartSeries(page.hrDayOffset) : [];
    }

    function setHrDay(offset) {
        page.hrDayOffset = Math.max(0, Math.min(page.hrMaxLookback, offset));
        page.reloadHeart();
    }

    function reload() {
        if (!StoandlClient.daemonUp) {
            page.summary = ({});
            page.stepSeries = [];
            page.sleepSegments = [];
            page.heartSeries = [];
            return;
        }
        page.summary = StoandlClient.healthSummary();
        page.stepSeries = StoandlClient.healthSeries("steps");
        page.sleepSegments = StoandlClient.sleepTimeline();
        page.hrDayOffset = 0;           // a fresh load / sync returns to today
        page.reloadHeart();
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

    // epoch seconds (local) -> "H:MM AM/PM"; 0/unset -> "—"
    function fmtClock(epoch) {
        if (!epoch || epoch <= 0) return "—";
        var d = new Date(epoch * 1000);
        var h = d.getHours(), mm = d.getMinutes();
        var ap = h < 12 ? "AM" : "PM";
        var h12 = h % 12; if (h12 === 0) h12 = 12;
        return h12 + ":" + (mm < 10 ? "0" + mm : mm) + " " + ap;
    }

    // Header for the sleep card — "Sleep · last night" when we woke today, else the wake date, since the
    // most recent night with data isn't always last night (derived from the summary's wakeup epoch).
    function sleepRecency() {
        var w = page.hasData ? (page.summary.sleepWakeup || 0) : 0;
        if (!w || w <= 0) return "Sleep";
        var wake = new Date(w * 1000), now = new Date();
        var dWake = new Date(wake.getFullYear(), wake.getMonth(), wake.getDate());
        var dNow = new Date(now.getFullYear(), now.getMonth(), now.getDate());
        var days = Math.round((dNow - dWake) / 86400000);
        if (days <= 0) return "Sleep · last night";
        return "Sleep · " + wake.toLocaleDateString(Qt.locale(), "ddd d MMM");
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
            icon.name: "love-symbolic"
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
            trailing: Kirigami.Icon {
                source: "view-statistics-symbolic"
                implicitWidth: Kirigami.Units.iconSizes.smallMedium
                implicitHeight: Kirigami.Units.iconSizes.smallMedium
                Layout.alignment: Qt.AlignVCenter
                opacity: 0.7
            }
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

        // ============ SLEEP (most recent night) ============
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp && page.hasData
            // "last night" when we woke today, otherwise the date of the most recent night with data
            // (the watch may have been syncing elsewhere, so the freshest sleep we hold can be older).
            title: page.sleepRecency()
            trailing: Kirigami.Icon {
                source: "weather-clear-night-symbolic"
                implicitWidth: Kirigami.Units.iconSizes.smallMedium
                implicitHeight: Kirigami.Units.iconSizes.smallMedium
                Layout.alignment: Qt.AlignVCenter
                opacity: 0.7
            }
        }

        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.hasData

            FormCard.AbstractFormDelegate {
                background: null
                Layout.fillWidth: true

                contentItem: ColumnLayout {
                    id: sleepCol
                    spacing: Kirigami.Units.largeSpacing

                    readonly property int deepMin: page.hasData ? (page.summary.sleepDeepMin || 0) : 0
                    readonly property int lightMin: page.hasData ? (page.summary.sleepLightMin || 0) : 0
                    readonly property int totalMin: page.hasData ? (page.summary.sleepTotalMin || 0) : 0
                    readonly property int typicalMin: page.hasData ? (page.summary.sleepTypicalMin || 0) : 0
                    readonly property real bedtime: page.hasData ? (page.summary.sleepBedtime || 0) : 0
                    readonly property real wakeup: page.hasData ? (page.summary.sleepWakeup || 0) : 0
                    readonly property bool haveSleep: totalMin > 0

                    // Pebble models two stages: light (the Sleep container) and deep (nested). One hue,
                    // deep solid + light faded, so the timeline reads as a single theme-driven band.
                    readonly property color deepTint: Kirigami.Theme.highlightColor
                    readonly property color lightTint: Qt.rgba(Kirigami.Theme.highlightColor.r,
                                                               Kirigami.Theme.highlightColor.g,
                                                               Kirigami.Theme.highlightColor.b, 0.35)

                    // Total + asleep, with the bedtime→wakeup span trailing.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Kirigami.Heading {
                            level: 1
                            text: sleepCol.haveSleep ? page.fmtMin(sleepCol.totalMin) : "—"
                        }
                        QQC2.Label {
                            text: "asleep"
                            opacity: 0.7
                            Layout.alignment: Qt.AlignBaseline
                        }
                        Item { Layout.fillWidth: true }
                        QQC2.Label {
                            visible: sleepCol.haveSleep
                            text: page.fmtClock(sleepCol.bedtime) + " → " + page.fmtClock(sleepCol.wakeup)
                            opacity: 0.7
                            font: Kirigami.Theme.smallFont
                            Layout.alignment: Qt.AlignBaseline
                        }
                    }

                    // No-sleep empty state (steps may still exist for today).
                    QQC2.Label {
                        visible: !sleepCol.haveSleep
                        Layout.fillWidth: true
                        text: "No sleep data yet — sync your watch to pull recent nights."
                        opacity: 0.6
                        font: Kirigami.Theme.smallFont
                    }

                    // Timeline: light/deep segments at their real times across a 6 PM→noon window.
                    Item {
                        id: sleepTrack
                        visible: sleepCol.haveSleep
                        Layout.fillWidth: true
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 1.5

                        Rectangle {
                            anchors.fill: parent
                            radius: height / 5
                            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                           Kirigami.Theme.textColor.b, 0.07)
                        }
                        Repeater {
                            model: page.sleepSegments
                            delegate: Rectangle {
                                required property var modelData
                                y: 0
                                height: parent.height
                                x: modelData.start * sleepTrack.width
                                width: Math.max(2, modelData.width * sleepTrack.width)
                                radius: height / 5
                                color: modelData.deep ? sleepCol.deepTint : sleepCol.lightTint
                            }
                        }
                    }

                    // Axis ticks for the 18 h window (6 PM yesterday → noon today).
                    Item {
                        id: sleepAxis
                        visible: sleepCol.haveSleep
                        Layout.fillWidth: true
                        Layout.preferredHeight: Kirigami.Units.gridUnit
                        Repeater {
                            model: [["6 PM", 0.0], ["12 AM", 0.3333], ["6 AM", 0.6667], ["noon", 1.0]]
                            delegate: QQC2.Label {
                                required property var modelData
                                text: modelData[0]
                                font: Kirigami.Theme.smallFont
                                opacity: 0.5
                                x: Math.max(0, Math.min(sleepAxis.width - width,
                                                        modelData[1] * sleepAxis.width - width / 2))
                            }
                        }
                    }

                    // Legend (deep / light) + 30-day typical.
                    RowLayout {
                        visible: sleepCol.haveSleep
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.largeSpacing
                        SleepLegend { tint: sleepCol.deepTint; name: "Deep"; mins: page.fmtMin(sleepCol.deepMin) }
                        SleepLegend { tint: sleepCol.lightTint; name: "Light"; mins: page.fmtMin(sleepCol.lightMin) }
                        Item { Layout.fillWidth: true }
                        QQC2.Label {
                            visible: sleepCol.typicalMin > 0
                            text: "Typical " + page.fmtMin(sleepCol.typicalMin)
                            opacity: 0.7
                            font: Kirigami.Theme.smallFont
                        }
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
            trailing: Kirigami.Icon {
                source: "love-symbolic"
                implicitWidth: Kirigami.Units.iconSizes.smallMedium
                implicitHeight: Kirigami.Units.iconSizes.smallMedium
                Layout.alignment: Qt.AlignVCenter
                opacity: 0.7
            }
        }

        FormCard.FormCard {
            visible: StoandlClient.daemonUp && page.hrAvailable

            FormCard.AbstractFormDelegate {
                background: null
                Layout.fillWidth: true

                contentItem: ColumnLayout {
                    spacing: Kirigami.Units.largeSpacing

                    // Day navigation — browse the last week of heart-rate history.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        QQC2.ToolButton {
                            icon.name: "go-previous-symbolic"
                            enabled: page.hrDayOffset < page.hrMaxLookback
                            onClicked: page.setHrDay(page.hrDayOffset + 1)   // an earlier day
                            QQC2.ToolTip.text: "Earlier day"
                            QQC2.ToolTip.visible: hovered
                            Accessible.name: "Earlier day"
                        }
                        QQC2.Label {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            text: page.hrDayLabel(page.hrDayOffset)
                            font.bold: true
                            elide: Text.ElideRight
                        }
                        QQC2.ToolButton {
                            icon.name: "go-next-symbolic"
                            enabled: page.hrDayOffset > 0
                            onClicked: page.setHrDay(page.hrDayOffset - 1)   // a more recent day
                            QQC2.ToolTip.text: "Later day"
                            QQC2.ToolTip.visible: hovered
                            Accessible.name: "Later day"
                        }
                    }

                    // Headline — today shows live vitals (Resting + Now); a past day shows that day's average.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.gridUnit
                        visible: page.hrDayOffset === 0

                        ColumnLayout {
                            spacing: 0
                            RowLayout {
                                spacing: Kirigami.Units.smallSpacing / 2
                                Kirigami.Heading {
                                    level: 1
                                    // Resting HR is derived from sleep — show — until a sleep session exists.
                                    text: (page.hrAvailable && page.summary.restingHr > 0) ? String(page.summary.restingHr) : "—"
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
                                    text: (page.hrAvailable && page.summary.currentHr > 0) ? String(page.summary.currentHr) : "—"
                                }
                                QQC2.Label { text: "bpm"; opacity: 0.7; Layout.alignment: Qt.AlignBaseline }
                            }
                            QQC2.Label { text: "Now"; font: Kirigami.Theme.smallFont; opacity: 0.7 }
                        }

                        Item { Layout.fillWidth: true }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        visible: page.hrDayOffset > 0 && page.hrStats.count > 0
                        ColumnLayout {
                            spacing: 0
                            RowLayout {
                                spacing: Kirigami.Units.smallSpacing / 2
                                Kirigami.Heading { level: 1; text: String(page.hrStats.avg) }
                                QQC2.Label { text: "bpm"; opacity: 0.7; Layout.alignment: Qt.AlignBaseline }
                            }
                            QQC2.Label { text: "Average"; font: Kirigami.Theme.smallFont; opacity: 0.7 }
                        }
                        Item { Layout.fillWidth: true }
                    }

                    // Empty state for a day with no readings.
                    QQC2.Label {
                        Layout.fillWidth: true
                        visible: page.hrStats.count === 0
                        text: "No heart-rate data for " + page.hrDayLabel(page.hrDayOffset).toLowerCase() + "."
                        opacity: 0.6
                        font: Kirigami.Theme.smallFont
                    }

                    // Minute-level sparkline, each sample at its true time of day (x = minute / 1440).
                    Canvas {
                        id: hrCanvas
                        visible: page.hrStats.count > 0
                        Layout.fillWidth: true
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 3

                        onPaint: {
                            var ctx = getContext("2d");
                            ctx.reset();
                            var data = page.heartSeries;
                            if (!data || data.length < 1) return;

                            var lo = page.hrStats.min, hi = page.hrStats.max;
                            var span = (hi - lo) || 1;
                            var w = width, h = height, pad = 3;

                            function px(min) { return (min / 1440) * w; }
                            function py(v) { return h - ((v - lo) / span) * (h - 2 * pad) - pad; }

                            var hr = Kirigami.Theme.negativeTextColor;
                            var n = data.length;

                            // A single reading can't form a line/area — draw a dot so the chart isn't blank.
                            if (n === 1) {
                                ctx.beginPath();
                                ctx.arc(px(data[0].minute), py(data[0].bpm), 3, 0, 2 * Math.PI);
                                ctx.fillStyle = hr;
                                ctx.fill();
                                return;
                            }

                            // Area fill (gradient -> transparent).
                            ctx.beginPath();
                            ctx.moveTo(px(data[0].minute), py(data[0].bpm));
                            for (var i = 1; i < n; ++i) ctx.lineTo(px(data[i].minute), py(data[i].bpm));
                            ctx.lineTo(px(data[n - 1].minute), h);
                            ctx.lineTo(px(data[0].minute), h);
                            ctx.closePath();
                            var grad = ctx.createLinearGradient(0, 0, 0, h);
                            grad.addColorStop(0, Qt.rgba(hr.r, hr.g, hr.b, 0.35));
                            grad.addColorStop(1, Qt.rgba(hr.r, hr.g, hr.b, 0.0));
                            ctx.fillStyle = grad;
                            ctx.fill();

                            // Line.
                            ctx.beginPath();
                            ctx.moveTo(px(data[0].minute), py(data[0].bpm));
                            for (i = 1; i < n; ++i) ctx.lineTo(px(data[i].minute), py(data[i].bpm));
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

                    // Hour axis (midnight → midnight), matching the granular chart above.
                    Item {
                        id: hrAxis
                        visible: page.hrStats.count > 0
                        Layout.fillWidth: true
                        Layout.preferredHeight: Kirigami.Units.gridUnit
                        Repeater {
                            model: [["12 AM", 0.0], ["6 AM", 0.25], ["12 PM", 0.5], ["6 PM", 0.75], ["12 AM", 1.0]]
                            delegate: QQC2.Label {
                                required property var modelData
                                text: modelData[0]
                                font: Kirigami.Theme.smallFont
                                opacity: 0.5
                                x: Math.max(0, Math.min(hrAxis.width - width, modelData[1] * hrAxis.width - width / 2))
                            }
                        }
                    }

                    // Range summary for the shown day (derived from its samples).
                    QQC2.Label {
                        Layout.fillWidth: true
                        visible: page.hrStats.count > 0
                        text: "min " + page.hrStats.min + " · max " + page.hrStats.max + " · avg " + page.hrStats.avg + " bpm"
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
