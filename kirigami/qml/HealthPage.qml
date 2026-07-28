import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// Read-only health dashboard. A single period selector (Daily / Weekly / Monthly) + one navigator at
// the top drive ALL three sections (steps / sleep / heart rate): Daily shows the rich per-day cards,
// Weekly/Monthly show per-day bar charts. Mirrors the official Pebble app's HealthTimeRange model.
// Everything is polled in C++ (healthSummary/stepsBars/sleepTimeline/sleepBars/heartSamples/heartBars);
// QML only renders. The one mutation is the explicit "Sync health" page action.
Kirigami.ScrollablePage {
    id: page
    objectName: "health"
    title: "Health"
    // The Daily/Weekly/Monthly switcher + navigator are pinned in the page `header` (below) so they
    // don't scroll; "Sync health" is a standard page action (header on desktop / footer on mobile).

    // --- period state ------------------------------------------------------
    property string periodType: "day"     // "day" | "week" | "month"
    property int periodOffset: 0           // 0 = current period, 1 = previous, …
    readonly property bool isDay: periodType === "day"

    // --- snapshots (parsed in C++) -----------------------------------------
    property var summary: ({})
    property var sleepSegments: []   // daily timeline [{start,width,deep}]
    property var heartSamples: []    // daily minute-level [{minute,bpm}]
    property var stepBarData: []     // week/month [{label,value,typical,hasValue}]
    property var sleepBarData: []    // week/month [{label,value(totalMin),deep,hasValue}]
    property var heartBarData: []    // week/month [{label,value(avgBpm),hasValue}]

    readonly property bool hasData: summary && summary.kind === "ok"
    readonly property bool hrAvailable: hasData && summary.hrAvailable === true

    // min / max / avg from the daily HR samples.
    readonly property var hrStats: {
        var arr = page.heartSamples;
        if (!arr || arr.length === 0) return { count: 0, min: 0, max: 0, avg: 0 };
        var lo = 1e9, hi = -1e9, sum = 0;
        for (var i = 0; i < arr.length; ++i) { var b = arr[i].bpm; if (b < lo) lo = b; if (b > hi) hi = b; sum += b; }
        return { count: arr.length, min: lo, max: hi, avg: Math.round(sum / arr.length) };
    }

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    // --- loaders -----------------------------------------------------------
    function reload() {
        if (!StoandlClient.daemonUp) {
            page.summary = ({});
            page.sleepSegments = []; page.heartSamples = [];
            page.stepBarData = []; page.sleepBarData = []; page.heartBarData = [];
            return;
        }
        page.summary = StoandlClient.healthSummary(page.periodType, page.periodOffset);
        // Steps always has a graph: hourly buckets (day) or per-day bars (week/month).
        page.stepBarData = StoandlClient.stepsBars(page.periodType, page.periodOffset);
        if (page.isDay) {
            page.sleepSegments = StoandlClient.sleepTimeline(page.periodType, page.periodOffset);
            page.heartSamples = page.hrAvailable ? StoandlClient.heartSamples(page.periodType, page.periodOffset) : [];
            page.sleepBarData = []; page.heartBarData = [];
        } else {
            page.sleepBarData = StoandlClient.sleepBars(page.periodType, page.periodOffset);
            page.heartBarData = page.hrAvailable ? StoandlClient.heartBars(page.periodType, page.periodOffset) : [];
            page.sleepSegments = []; page.heartSamples = [];
        }
    }

    function maxOffsetFor(t) { return t === "day" ? 30 : t === "week" ? 12 : 11; }

    function setPeriodType(t) {
        if (t === page.periodType) return;
        page.periodType = t;
        page.periodOffset = 0;
        page.reload();
    }
    function setPeriodOffset(o) {
        page.periodOffset = Math.max(0, Math.min(page.maxOffsetFor(page.periodType), o));
        page.reload();
    }

    // The navigator label for the current (periodType, offset) — must match the daemon's windows.
    function periodLabel() {
        if (page.periodType === "day") {
            if (page.periodOffset === 0) return "Today";
            if (page.periodOffset === 1) return "Yesterday";
            var d = new Date(); d.setDate(d.getDate() - page.periodOffset);
            return d.toLocaleDateString(Qt.locale(), "ddd d MMM");
        }
        if (page.periodType === "week") {
            if (page.periodOffset === 0) return "This week";
            var end = new Date(); end.setDate(end.getDate() - page.periodOffset * 7);
            var start = new Date(end); start.setDate(end.getDate() - 6);
            return start.toLocaleDateString(Qt.locale(), "d MMM") + " – " + end.toLocaleDateString(Qt.locale(), "d MMM");
        }
        if (page.periodOffset === 0) return "This month";
        var m = new Date(); m.setDate(1); m.setMonth(m.getMonth() - page.periodOffset);
        return m.toLocaleDateString(Qt.locale(), "MMMM yyyy");
    }

    function syncHealth() {
        var r = StoandlClient.syncHealth();
        if (r.ok) page.toast("Syncing health data…");
        else if (r.kind === "notready") page.toast("No watch connected");
        else if (r.tail.toLowerCase().indexOf("not enabled") !== -1)
            page.toast("Health sync is disabled — enable it in Settings");
        else page.toast("Health: " + (r.tail !== "" ? r.tail : r.kind));
        page.reload();
    }

    // minutes -> "Hh MMm"
    function fmtMin(m) {
        var mm = String(Math.round(m) % 60);
        if (mm.length < 2) mm = "0" + mm;
        return Math.floor(Math.round(m) / 60) + "h " + mm + "m";
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
    // "asleep" for daily, "avg / night" for a multi-day period.
    function sleepUnit() { return page.isDay ? "asleep" : "avg / night"; }

    // The daily sleep card falls back to the most recent recorded night when the selected day (Today)
    // has none yet — stoandl's sleep data is inherently a night-or-more behind (the watch hands each
    // night's overlay over late; consume-once). Detect the fallback here from the returned wake epoch:
    // if the shown night's wake date isn't the day the navigator points at, it's a fallback → we
    // date-label it. Single source of truth = summary.sleepWakeup, so no extra D-Bus field is needed.
    readonly property bool sleepIsFallback: {
        if (!page.isDay || !page.hasData) return false;
        var w = page.summary.sleepWakeup || 0;
        if (w <= 0) return false;
        var wake = new Date(w * 1000); wake.setHours(0, 0, 0, 0);
        var target = new Date(); target.setHours(0, 0, 0, 0);
        target.setDate(target.getDate() - page.periodOffset);
        return wake.getTime() !== target.getTime();
    }
    // The shown night's date, from its wake epoch, e.g. "Mon 30 Jun".
    function sleepNightDate() {
        var w = page.hasData ? (page.summary.sleepWakeup || 0) : 0;
        var d = w > 0 ? new Date(w * 1000) : new Date();
        return d.toLocaleDateString(Qt.locale(), "ddd d MMM");
    }
    // The night's day-span as short weekday names — bedtime day → wake day, e.g. "Di–Mi" (went to
    // bed Tuesday, woke Wednesday). Strips the locale's trailing "." on the abbreviation.
    function sleepNightSpan() {
        var b = page.hasData ? (page.summary.sleepBedtime || 0) : 0;
        var w = page.hasData ? (page.summary.sleepWakeup || 0) : 0;
        if (b > 0 && w > 0) {
            var bd = new Date(b * 1000).toLocaleDateString(Qt.locale(), "ddd").replace(/\.$/, "");
            var wd = new Date(w * 1000).toLocaleDateString(Qt.locale(), "ddd").replace(/\.$/, "");
            return bd === wd ? bd : (bd + "–" + wd);
        }
        return page.sleepNightDate();
    }
    function stepsUnit() { return page.isDay ? "steps" : "avg / day"; }
    // Compact step count for the y-axis (7432 → "7.4k", 12000 → "12k", 800 → "800").
    function fmtK(v) {
        return v >= 10000 ? Math.round(v / 1000) + "k" : v >= 1000 ? (v / 1000).toFixed(1) + "k" : String(Math.round(v));
    }

    Connections {
        target: StoandlClient
        function onDaemonUpChanged() { if (StoandlClient.daemonUp) page.reload(); }
    }

    Component.onCompleted: page.reload()

    actions: [
        Kirigami.Action {
            icon.name: "view-refresh-symbolic"
            text: "Sync health"
            enabled: StoandlClient.daemonUp
            onTriggered: page.syncHealth()
        }
    ]

    // Pinned period control — the Daily/Weekly/Monthly switcher + navigator stay at the top while the
    // metric cards scroll. Drives all three sections.
    header: QQC2.ToolBar {
        visible: StoandlClient.daemonUp
        height: visible ? implicitHeight : 0
        position: QQC2.ToolBar.Header
        contentItem: ColumnLayout {
            spacing: Kirigami.Units.smallSpacing
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                Repeater {
                    model: [["day", "Daily"], ["week", "Weekly"], ["month", "Monthly"]]
                    delegate: QQC2.Button {
                        required property var modelData
                        Layout.fillWidth: true
                        text: modelData[1]
                        checkable: true
                        autoExclusive: true
                        checked: page.periodType === modelData[0]
                        onClicked: page.setPeriodType(modelData[0])
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                QQC2.ToolButton {
                    icon.name: "go-previous-symbolic"
                    enabled: page.periodOffset < page.maxOffsetFor(page.periodType)
                    onClicked: page.setPeriodOffset(page.periodOffset + 1)
                    Accessible.name: "Earlier"
                    QQC2.ToolTip.text: "Earlier"
                    QQC2.ToolTip.visible: hovered
                }
                QQC2.Label {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: page.periodLabel()
                    font.bold: true
                    elide: Text.ElideRight
                }
                QQC2.ToolButton {
                    icon.name: "go-next-symbolic"
                    enabled: page.periodOffset > 0
                    onClicked: page.setPeriodOffset(page.periodOffset - 1)
                    Accessible.name: "Later"
                    QQC2.ToolTip.text: "Later"
                    QQC2.ToolTip.visible: hovered
                }
            }
        }
    }

    ColumnLayout {
        spacing: 0

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
            icon.name: "stoandl-heart-symbolic"   // bundled monochrome heart (Breeze hearts are colored)
            text: "No health data yet"
            explanation: "Sync your watch to pull steps, sleep and heart-rate history. "
                       + "Health tracking must be enabled in Settings."
            helpfulAction: Kirigami.Action {
                icon.name: "view-refresh-symbolic"
                text: "Sync health"
                onTriggered: page.syncHealth()
            }
        }

        // ============ STEPS ============
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp && page.hasData
            title: "Steps"
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

                    // Headline: the period's total (day) or avg/day, + typical.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Kirigami.Heading {
                            level: 1
                            text: page.hasData ? String(page.isDay ? page.summary.stepsTotal : page.summary.stepsAvgPerDay) : "—"
                        }
                        QQC2.Label { text: page.stepsUnit(); opacity: 0.7; Layout.alignment: Qt.AlignBaseline }
                        Item { Layout.fillWidth: true }
                        QQC2.Label {
                            visible: page.hasData && page.summary.stepsTypical > 0
                            text: "Typical " + (page.hasData ? page.summary.stepsTypical : 0)
                            opacity: 0.7
                            font: Kirigami.Theme.smallFont
                            Layout.alignment: Qt.AlignBaseline
                        }
                    }

                    // Daily: hourly step bars (when you walked).
                    MetricBars {
                        visible: page.isDay
                        Layout.fillWidth: true
                        model: page.stepBarData
                        tint: Kirigami.Theme.highlightColor
                        hourly: true
                        formatLabel: function (v) { return page.fmtK(v); }
                    }

                    // Daily: distance / calories / active tiles.
                    RowLayout {
                        visible: page.isDay
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.largeSpacing
                        StatTile { Layout.fillWidth: true; value: (page.hasData ? page.summary.distanceKm : "—") + " km"; label: "Distance" }
                        StatTile { Layout.fillWidth: true; value: page.hasData ? String(page.summary.kcal) : "—"; label: "Calories" }
                        StatTile { Layout.fillWidth: true; value: (page.hasData ? page.summary.activeMin : "—") + " min"; label: "Active" }
                    }

                    // Weekly/Monthly: per-day step bars with a faint "typical" reference line.
                    MetricBars {
                        visible: !page.isDay
                        Layout.fillWidth: true
                        model: page.stepBarData
                        tint: Kirigami.Theme.highlightColor
                        refLine: page.hasData ? page.summary.stepsTypical : 0
                        formatLabel: function (v) { return page.fmtK(v); }
                    }
                    QQC2.Label {
                        visible: !page.isDay && page.hasData
                        Layout.fillWidth: true
                        text: "Total " + (page.hasData ? page.summary.stepsTotal : 0) + " over " + (page.hasData ? page.summary.daysWithData : 0) + " days"
                        font: Kirigami.Theme.smallFont
                        opacity: 0.6
                    }
                }
            }
        }

        // ============ SLEEP ============
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp && page.hasData
            title: "Sleep"
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

                    // Light = the accent; Deep = a darker SOLID shade of it. Both solid (not opacity of one
                    // colour) so "deep darker than light" holds in BOTH light and dark themes — a translucent
                    // tint composites darker over a dark background, which inverted deep/light there.
                    readonly property color lightTint: Kirigami.Theme.highlightColor
                    readonly property color deepTint: Qt.darker(Kirigami.Theme.highlightColor, 1.6)

                    // Headline: total (day) / avg per night (period) + bedtime→wakeup (day only).
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Kirigami.Heading { level: 1; text: sleepCol.haveSleep ? page.fmtMin(sleepCol.totalMin) : "—" }
                        QQC2.Label { text: page.sleepUnit(); opacity: 0.7; Layout.alignment: Qt.AlignBaseline }
                        Item { Layout.fillWidth: true }
                        QQC2.Label {
                            visible: page.isDay && sleepCol.haveSleep
                            text: page.fmtClock(sleepCol.bedtime) + " → " + page.fmtClock(sleepCol.wakeup)
                            opacity: 0.7
                            font: Kirigami.Theme.smallFont
                            Layout.alignment: Qt.AlignBaseline
                        }
                    }

                    // "Last recorded night · <date>" when the Today card is showing an earlier night
                    // because today's sleep hasn't reached stoandl yet (see resolveSleepDay daemon-side).
                    QQC2.Label {
                        visible: page.isDay && sleepCol.haveSleep && page.sleepIsFallback
                        Layout.fillWidth: true
                        text: "Last recorded night · " + page.sleepNightSpan()
                        opacity: 0.7
                        font: Kirigami.Theme.smallFont
                    }

                    QQC2.Label {
                        visible: !sleepCol.haveSleep
                        Layout.fillWidth: true
                        text: page.periodOffset === 0 ? "No sleep data yet."
                             : page.isDay ? "No sleep recorded for this day."
                                          : "No sleep recorded for this period."
                        opacity: 0.6
                        font: Kirigami.Theme.smallFont
                    }

                    // Daily: the night's light/deep timeline across a 6 PM → noon window.
                    Item {
                        id: sleepTrack
                        visible: page.isDay && sleepCol.haveSleep
                        Layout.fillWidth: true
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 1.5
                        Rectangle {
                            anchors.fill: parent
                            radius: height / 5
                            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.07)
                        }
                        Repeater {
                            model: page.sleepSegments
                            delegate: Rectangle {
                                required property var modelData
                                y: 0; height: parent.height
                                x: modelData.start * sleepTrack.width
                                width: Math.max(2, modelData.width * sleepTrack.width)
                                radius: height / 5
                                color: modelData.deep ? sleepCol.deepTint : sleepCol.lightTint
                            }
                        }
                    }
                    Item {
                        id: sleepAxis
                        visible: page.isDay && sleepCol.haveSleep
                        Layout.fillWidth: true
                        Layout.preferredHeight: Kirigami.Units.gridUnit
                        Repeater {
                            model: [["6 PM", 0.0], ["12 AM", 0.3333], ["6 AM", 0.6667], ["noon", 1.0]]
                            delegate: QQC2.Label {
                                required property var modelData
                                text: modelData[0]
                                font: Kirigami.Theme.smallFont
                                opacity: 0.5
                                x: Math.max(0, Math.min(sleepAxis.width - width, modelData[1] * sleepAxis.width - width / 2))
                            }
                        }
                    }

                    // Weekly/Monthly: per-night stacked bars (light band, darker deep base), y-axis in hours.
                    MetricBars {
                        visible: !page.isDay
                        Layout.fillWidth: true
                        model: page.sleepBarData
                        tint: Kirigami.Theme.highlightColor
                        barColor: sleepCol.lightTint
                        deepColor: sleepCol.deepTint
                        valueToHeight: function (v) { return v / 60.0; }   // minutes → hours
                        formatLabel: function (v) { return Math.round(v) + "h"; }
                    }

                    // Legend (deep / light) + typical — daily only (the bars are self-explanatory).
                    RowLayout {
                        visible: page.isDay && sleepCol.haveSleep
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
                    QQC2.Label {
                        visible: !page.isDay && sleepCol.haveSleep && sleepCol.typicalMin > 0
                        Layout.fillWidth: true
                        text: "Typical " + page.fmtMin(sleepCol.typicalMin) + " / night"
                        font: Kirigami.Theme.smallFont
                        opacity: 0.6
                    }
                }
            }
        }

        // ============ HEART RATE (only when available) ============
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp && page.hrAvailable
            title: "Heart rate"
            trailing: Kirigami.Icon {
                source: "stoandl-heart-symbolic"   // bundled monochrome heart (Breeze hearts are colored)
                isMask: true                        // Kirigami.Icon can force monochrome here (the tab can't)
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

                    // Heart-rate stats in one row: Resting · Average · Min · Max. Resting is the primary
                    // (large) stat (or Average if there's no sleep-derived resting). Min/Max come from the
                    // day's minute samples, so they show in the daily view only; week/month shows the first two.
                    RowLayout {
                        id: hrStatsRow
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.largeSpacing
                        visible: page.isDay ? page.hrStats.count > 0 : (page.hasData && page.summary.hrAvg > 0)
                        readonly property bool restingPrimary: page.summary.hrResting > 0
                        readonly property int avgVal: page.isDay ? page.hrStats.avg : page.summary.hrAvg
                        HrStat { visible: hrStatsRow.restingPrimary; primary: true; value: String(page.summary.hrResting); label: "Resting" }
                        HrStat { visible: hrStatsRow.avgVal > 0; primary: !hrStatsRow.restingPrimary; value: String(hrStatsRow.avgVal); label: "Average" }
                        Item { Layout.fillWidth: true }   // Resting/Average left, Min/Max right
                        HrStat { visible: page.isDay && page.hrStats.count > 0; value: String(page.hrStats.min); label: "Min" }
                        HrStat { visible: page.isDay && page.hrStats.count > 0; value: String(page.hrStats.max); label: "Max" }
                    }

                    // Empty state (a day with no samples, or a week/month with no readings at all even
                    // though the watch has an HRM → hrAvg is 0).
                    QQC2.Label {
                        Layout.fillWidth: true
                        visible: page.isDay ? page.hrStats.count === 0 : (page.hasData && page.summary.hrAvg <= 0)
                        text: "No heart-rate data for " + page.periodLabel().toLowerCase() + "."
                        opacity: 0.6
                        font: Kirigami.Theme.smallFont
                    }

                    // Daily: minute-level HR line with a left bpm y-axis + min/max/avg overlaid top-right.
                    Item {
                        id: hrChart
                        visible: page.isDay && page.hrStats.count > 0
                        Layout.fillWidth: true
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 5
                        readonly property real gutter: Kirigami.Units.gridUnit * 2.2
                        readonly property int plotPad: 3
                        function yOf(frac) { return hrChart.height - frac * (hrChart.height - 2 * hrChart.plotPad) - hrChart.plotPad; }

                        // y-axis: gridlines + bpm tick labels (min / mid / max).
                        Repeater {
                            model: [0.0, 0.5, 1.0]
                            delegate: Item {
                                required property real modelData
                                anchors.fill: parent
                                Rectangle {
                                    x: hrChart.gutter; width: hrChart.width - hrChart.gutter; height: 1
                                    y: hrChart.yOf(parent.modelData)
                                    color: Kirigami.Theme.disabledTextColor; opacity: 0.2
                                }
                                QQC2.Label {
                                    x: 0; width: hrChart.gutter - Kirigami.Units.smallSpacing
                                    y: Math.max(0, Math.min(hrChart.height - height, hrChart.yOf(parent.modelData) - height / 2))
                                    horizontalAlignment: Text.AlignRight
                                    text: String(Math.round(page.hrStats.min + parent.modelData * (page.hrStats.max - page.hrStats.min)))
                                    font: Kirigami.Theme.smallFont; opacity: 0.6
                                }
                            }
                        }

                        Canvas {
                            id: hrCanvas
                            anchors.fill: parent
                            anchors.leftMargin: hrChart.gutter
                            onPaint: {
                                var ctx = getContext("2d");
                                ctx.reset();
                                var data = page.heartSamples;
                                if (!data || data.length < 1) return;
                                var lo = page.hrStats.min, hi = page.hrStats.max;
                                var span = (hi - lo) || 1;
                                var w = width, h = height, pad = hrChart.plotPad;
                                function px(min) { return (min / 1440) * w; }
                                function py(v) { return h - ((v - lo) / span) * (h - 2 * pad) - pad; }
                                var hr = Kirigami.Theme.negativeTextColor;
                                var n = data.length;
                                if (n === 1) {
                                    ctx.beginPath(); ctx.arc(px(data[0].minute), py(data[0].bpm), 3, 0, 2 * Math.PI);
                                    ctx.fillStyle = hr; ctx.fill(); return;
                                }
                                ctx.beginPath();
                                ctx.moveTo(px(data[0].minute), py(data[0].bpm));
                                for (var i = 1; i < n; ++i) ctx.lineTo(px(data[i].minute), py(data[i].bpm));
                                ctx.lineTo(px(data[n - 1].minute), h); ctx.lineTo(px(data[0].minute), h); ctx.closePath();
                                var grad = ctx.createLinearGradient(0, 0, 0, h);
                                grad.addColorStop(0, Qt.rgba(hr.r, hr.g, hr.b, 0.35));
                                grad.addColorStop(1, Qt.rgba(hr.r, hr.g, hr.b, 0.0));
                                ctx.fillStyle = grad; ctx.fill();
                                ctx.beginPath();
                                ctx.moveTo(px(data[0].minute), py(data[0].bpm));
                                for (i = 1; i < n; ++i) ctx.lineTo(px(data[i].minute), py(data[i].bpm));
                                ctx.lineWidth = 2; ctx.lineJoin = "round"; ctx.strokeStyle = hr; ctx.stroke();
                            }
                            Connections { target: page; function onHeartSamplesChanged() { hrCanvas.requestPaint(); } }
                            Connections { target: Kirigami.Theme; function onColorsChanged() { hrCanvas.requestPaint(); } }
                        }
                    }
                    Item {
                        id: hrAxis
                        visible: page.isDay && page.hrStats.count > 0
                        Layout.fillWidth: true
                        Layout.leftMargin: hrChart.gutter   // align the time labels under the plot
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

                    // Weekly/Monthly: per-day average-HR bars.
                    MetricBars {
                        visible: !page.isDay && page.hasData && page.summary.hrAvg > 0
                        Layout.fillWidth: true
                        model: page.heartBarData
                        tint: Kirigami.Theme.negativeTextColor
                        floorAtMin: true   // HR bars read better from a non-zero floor
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
            Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
            text: parent.value; font.bold: true
            font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.1
            elide: Text.ElideRight
        }
        QQC2.Label {
            Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
            text: parent.label; font: Kirigami.Theme.smallFont; opacity: 0.7
        }
    }

    // --- a heart-rate stat (number + "bpm" over a label; `primary` = large + accent) --------
    component HrStat: ColumnLayout {
        id: stat
        property string value
        property string label
        property bool primary: false
        spacing: 0
        RowLayout {
            spacing: Kirigami.Units.smallSpacing / 2
            Kirigami.Heading {
                level: stat.primary ? 1 : 3
                text: stat.value
                color: stat.primary ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
            }
            QQC2.Label { text: "bpm"; opacity: 0.7; Layout.alignment: Qt.AlignBaseline }
        }
        QQC2.Label { text: stat.label; font: Kirigami.Theme.smallFont; opacity: 0.7 }
    }

    // --- a sleep-stage legend entry (swatch + "Name 1h 48m") ---------------
    component SleepLegend: RowLayout {
        property color tint
        property string name
        property string mins
        spacing: Kirigami.Units.smallSpacing
        Rectangle {
            implicitWidth: Kirigami.Units.iconSizes.small; implicitHeight: Kirigami.Units.iconSizes.small
            radius: height / 2; color: parent.tint; Layout.alignment: Qt.AlignVCenter   // a round dot
        }
        QQC2.Label { text: parent.name; font: Kirigami.Theme.smallFont; opacity: 0.7 }
        QQC2.Label { text: parent.mins; font.pointSize: Kirigami.Theme.smallFont.pointSize; font.bold: true }
    }

    // --- a reusable bar chart with a left y-axis (weekly/monthly/hourly) ----
    // model rows: {label, value, hasValue, deep?(stacked)}. A 3-tick y-axis (0/50%/100% of the value
    // range) with `formatLabel`-formatted ticks sits in the left `gutter`; `refLine` draws the metric's
    // "typical" line; `valueToHeight` rescales for the height axis (sleep min→h); `floorAtMin` floors at
    // the series min (HR never starts at 0). Non-floored charts round the top to a `niceCeil` ceiling.
    component MetricBars: ColumnLayout {
        id: bars
        property var model: []
        property color tint: Kirigami.Theme.highlightColor
        property real refLine: 0
        property var valueToHeight: null     // value → height-axis domain (e.g. sleep min → hours)
        property var formatLabel: null        // height-axis value → y-tick string (default: rounded)
        property bool floorAtMin: false       // floor the y-axis at the series min (HR, never starts at 0)
        property bool hourly: false           // 24 bars → a 12a/6a/12p/6p time axis instead of per-bar labels
        // Bar fill + the stacked `deep` portion's fill (sleep overrides these to match the timeline).
        property color barColor: Qt.rgba(bars.tint.r, bars.tint.g, bars.tint.b, 0.4)
        property color deepColor: bars.tint
        spacing: Kirigami.Units.smallSpacing

        // Width of the left y-axis gutter (holds the tick labels).
        readonly property real gutter: Kirigami.Units.gridUnit * 2.2
        function h(v) { return bars.valueToHeight ? bars.valueToHeight(v) : v; }
        function fmt(v) { return bars.formatLabel ? bars.formatLabel(v) : String(Math.round(v)); }
        // Round a value up to a "nice" axis ceiling (1/1.2/1.5/2/2.5/3/4/5/7.5/10 × 10ⁿ).
        function niceCeil(x) {
            if (x <= 0) return 1;
            var p = Math.pow(10, Math.floor(Math.log(x) / Math.LN10));
            var n = x / p;
            var c = n <= 1 ? 1 : n <= 1.2 ? 1.2 : n <= 1.5 ? 1.5 : n <= 2 ? 2 : n <= 2.5 ? 2.5
                  : n <= 3 ? 3 : n <= 4 ? 4 : n <= 5 ? 5 : n <= 7.5 ? 7.5 : 10;
            return c * p;
        }
        readonly property real floor: {
            if (!bars.floorAtMin) return 0;
            var lo = 1e9;
            for (var i = 0; i < bars.model.length; ++i)
                if (bars.model[i].hasValue && bars.h(bars.model[i].value) < lo) lo = bars.h(bars.model[i].value);
            return lo === 1e9 ? 0 : lo;   // floor at the actual min so the bottom tick is a real value
        }
        readonly property real barTop: {
            var m = bars.h(bars.refLine);
            for (var i = 0; i < bars.model.length; ++i)
                if (bars.model[i].hasValue && bars.h(bars.model[i].value) > m) m = bars.h(bars.model[i].value);
            // For a zero-floored chart, round up to a clean ceiling so the y-axis labels read nicely.
            return bars.floorAtMin ? Math.max(bars.floor + 1, m) : Math.max(1, bars.niceCeil(m));
        }
        readonly property int labelEvery: Math.max(1, Math.ceil(bars.model.length / 8))

        Item {
            id: chart
            Layout.fillWidth: true
            Layout.preferredHeight: Kirigami.Units.gridUnit * 6
            function yOf(frac) { return chart.height - frac * chart.height; }

            // y-axis: faint gridlines + a tick label at 0 / 50% / 100% of the value range.
            Repeater {
                model: [0.0, 0.5, 1.0]
                delegate: Item {
                    required property real modelData
                    anchors.fill: parent
                    Rectangle {
                        x: bars.gutter; width: chart.width - bars.gutter; height: 1
                        y: chart.yOf(parent.modelData)
                        color: Kirigami.Theme.disabledTextColor; opacity: 0.2
                    }
                    QQC2.Label {
                        x: 0; width: bars.gutter - Kirigami.Units.smallSpacing
                        // Keep the top/bottom ticks inside the chart rather than half-clipped on the edge.
                        y: Math.max(0, Math.min(chart.height - height, chart.yOf(parent.modelData) - height / 2))
                        horizontalAlignment: Text.AlignRight
                        text: bars.fmt(bars.floor + parent.modelData * (bars.barTop - bars.floor))
                        font: Kirigami.Theme.smallFont; opacity: 0.6; elide: Text.ElideRight
                    }
                }
            }

            // typical reference line (the metric accent, so it stands apart from the grey gridlines).
            Rectangle {
                visible: bars.refLine > 0
                x: bars.gutter; width: chart.width - bars.gutter; height: 1
                color: bars.tint; opacity: 0.6
                y: chart.yOf((bars.h(bars.refLine) - bars.floor) / (bars.barTop - bars.floor))
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: bars.gutter
                spacing: Math.max(1, Kirigami.Units.smallSpacing / 2)
                Repeater {
                    model: bars.model
                    delegate: Item {
                        id: cell
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Rectangle {   // total / value bar (faded)
                            anchors.bottom: parent.bottom
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: Math.max(2, parent.width * 0.7)
                            height: cell.modelData.hasValue
                                    ? Math.max(2, (bars.h(cell.modelData.value) - bars.floor) / (bars.barTop - bars.floor) * cell.height)
                                    : 0
                            radius: Math.min(width / 3, 3)
                            color: bars.barColor
                        }
                        Rectangle {   // stacked sub-portion (sleep "deep"), at the base
                            visible: (cell.modelData.deep || 0) > 0
                            anchors.bottom: parent.bottom
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: Math.max(2, parent.width * 0.7)
                            height: Math.max(1, bars.h(cell.modelData.deep || 0) / (bars.barTop - bars.floor) * cell.height)
                            radius: Math.min(width / 3, 3)
                            color: bars.deepColor
                        }
                    }
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: bars.gutter
            spacing: Math.max(1, Kirigami.Units.smallSpacing / 2)
            Repeater {
                model: bars.model
                delegate: QQC2.Label {
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: bars.hourly
                          ? (index === 0 ? "12 AM" : index === 6 ? "6 AM" : index === 12 ? "12 PM" : index === 18 ? "6 PM" : "")
                          : ((index % bars.labelEvery === 0) ? modelData.label : "")
                    font: Kirigami.Theme.smallFont
                    opacity: 0.6
                    elide: Text.ElideRight
                }
            }
        }
    }
}
