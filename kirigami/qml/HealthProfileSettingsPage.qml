import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// The watch's health *profile* — its own activity-tracking configuration (body metrics + tracking
// toggles + HR zones), written to the watch's HealthParams BlobDB via GetHealthProfile / SetHealthProfile.
// This is the WRITE side of health; the Health tab shows the read-only synced data. Applied per field
// and synced to the watch (needs a health-capable watch to take effect). Each row's (?) says what the
// watch does with it; the one-of-several rows open the page's one OptionPicker.
Kirigami.ScrollablePage {
    id: page
    objectName: "healthProfile"
    title: "Health profile"

    property var profile: ({})   // {key: value(string)}

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    function reload() {
        if (!StoandlClient.daemonUp) { page.profile = ({}); page.applyAllowed({}); return; }
        page.profile = StoandlClient.healthProfile();
        page.applyAllowed(page.profile);
    }

    // The intervals the daemon accepts right now (GetHealthProfile's third field: 5min only with a
    // watch on fw 4.39.0+ connected, or when it is already set). An older daemon sends none: offer
    // the four every firmware takes. Reassigned only on a change, so an open popup isn't reset.
    readonly property var baseIntervals: ["10min", "30min", "1h", "off"]
    property var intervalOptions: baseIntervals
    function applyAllowed(p) {
        var a = ((p || {})._allowed || {})["hrm_interval"];
        var next = (a && a.length) ? a : page.baseIntervals;
        if (JSON.stringify(next) !== JSON.stringify(page.intervalOptions)) page.intervalOptions = next;
    }

    // Set one field, then re-read so the shown values stay authoritative (the daemon may normalise).
    function apply(key, value) {
        var r = StoandlClient.setHealthProfile(key, value);
        if (!r.ok) page.toast((r.tail !== "" ? r.tail : r.kind));
        page.reload();
    }

    function val(key) { return (page.profile || {})[key] || ""; }
    // A stored token as a row shows it: "10min" → "10 min", "metric" → "Metric".
    function label(v) {
        var t = String(v).replace(/^(\d+)(min|h)$/, "$1 $2");
        return t.charAt(0).toUpperCase() + t.slice(1);
    }
    // One picker for the option rows, built on first use; the pick is written as its token.
    function pick(title, key, options, fallback) {
        pickerLoader.active = true;
        pickerLoader.item.choose(title, options.map(page.label), page.comboIndex(options, key, fallback),
                                 function (i) { page.apply(key, options[i]); });
    }
    function boolVal(key) { return page.val(key) === "on"; }
    // [fallback] is the entry to show while the value is unknown (the profile is empty before the daemon is ready).
    readonly property string bodyHelp: "Used by the watch to estimate distance, calories and sleep. Stored on the watch and this device only."

    function comboIndex(options, key, fallback) {
        var i = options.indexOf(page.val(key));
        if (i < 0) i = options.indexOf(fallback);
        return i >= 0 ? i : 0;
    }

    // Smoke hook (Settings → Health & battery's link runs it): the Units picker, its stored option written
    // back unchanged.
    function smokeExercise() {
        page.pick("Units", "units", page.unitOptions);
        var pk = pickerLoader.item;
        console.log("stoandl-smoke: health profile picker '" + pk.title + "' " + pk.options.join("|") + " checked "
                    + pk.currentIndex);
        pk.pick(pk.currentIndex);
        console.log("stoandl-smoke: health profile units = " + page.val("units"));
    }

    Connections {
        target: StoandlClient
        function onDaemonUpChanged() { if (StoandlClient.daemonUp) page.reload(); }
        // A watch connecting or leaving changes which intervals the daemon accepts. Only the choices
        // are refreshed, so a half-typed field isn't overwritten.
        function onWatchesChanged(rows) { if (StoandlClient.daemonUp) page.applyAllowed(StoandlClient.healthProfile()); }
    }

    Component.onCompleted: page.reload()

    readonly property var unitOptions: ["metric", "imperial"]
    readonly property var genderOptions: ["female", "male", "other"]

    // The daemon's D-Bus contract is ALWAYS metric — GetHealthProfile returns height_cm in cm and
    // weight_kg in kg, and SetHealthProfile always parses those units, regardless of the "units" field
    // (which is just the watch's own imperial/metric display preference). So when the profile is
    // imperial we present ft/in + lb purely client-side: convert on display, convert back before write.
    readonly property bool imperial: page.val("units") === "imperial"
    readonly property real cmPerInch: 2.54
    readonly property real lbPerKg: 2.2046226218

    // height_cm (string) → whole feet / remaining whole inches, rounded to the nearest inch so ft·12+in
    // always round-trips (e.g. 170 cm → 67 in → 5 ft 7 in, never a stray 6.93 in).
    function heightTotalInches() {
        var cm = parseFloat(page.val("height_cm"));
        return isNaN(cm) ? NaN : Math.round(cm / page.cmPerInch);
    }
    function heightFeet() {
        var ti = page.heightTotalInches();
        return isNaN(ti) ? "" : String(Math.floor(ti / 12));
    }
    function heightInches() {
        var ti = page.heightTotalInches();
        return isNaN(ti) ? "" : String(ti % 12);
    }
    function applyHeightImperial(feetText, inchText) {
        var ft = parseInt(feetText, 10);
        var inch = parseFloat(inchText);
        if (isNaN(ft)) ft = 0;
        if (isNaN(inch)) inch = 0;
        var cm = (ft * 12 + inch) * page.cmPerInch;
        page.apply("height_cm", String(Math.round(cm * 10) / 10));
    }

    // weight_kg (string) ↔ lb, one decimal.
    function weightLb() {
        var kg = parseFloat(page.val("weight_kg"));
        return isNaN(kg) ? "" : String(Math.round(kg * page.lbPerKg * 10) / 10);
    }
    function applyWeightImperial(lbText) {
        var lb = parseFloat(lbText);
        if (isNaN(lb)) return;
        page.apply("weight_kg", String(Math.round((lb / page.lbPerKg) * 10) / 10));
    }

    ColumnLayout {
        spacing: 0

        DaemonPlaceholder {
            visible: !StoandlClient.daemonUp
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 4
        }

        // --- Body profile -------------------------------------------------
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp
            title: "You"
        }
        FormCard.FormCard {
            visible: StoandlClient.daemonUp

            // Height — metric: one cm field; imperial: feet + inches. Both representations stay present
            // (visibility-toggled) so each keeps its own text binding: switching units re-reads the
            // now-visible field from the reloaded (still-metric) profile instead of a broken binding.
            FormTextRow {
                id: heightCmField
                visible: !page.imperial
                label: "Height (cm)"
                help: page.bodyHelp
                value: page.val("height_cm")
                inputMethodHints: Qt.ImhDigitsOnly
                onEditingFinished: if (visible && value !== page.val("height_cm")) page.apply("height_cm", value)
            }
            FormTextRow {
                id: heightFtField
                visible: page.imperial
                label: "Height (ft)"
                help: page.bodyHelp
                value: page.heightFeet()
                inputMethodHints: Qt.ImhDigitsOnly
                onEditingFinished: if (visible && value !== page.heightFeet()) page.applyHeightImperial(value, heightInField.value)
            }
            FormCard.FormDelegateSeparator { visible: page.imperial }
            FormTextRow {
                id: heightInField
                visible: page.imperial
                label: "Height (in)"
                help: page.bodyHelp
                value: page.heightInches()
                inputMethodHints: Qt.ImhFormattedNumbersOnly
                onEditingFinished: if (visible && value !== page.heightInches()) page.applyHeightImperial(heightFtField.value, value)
            }
            FormCard.FormDelegateSeparator {}
            FormTextRow {
                id: weightKgField
                visible: !page.imperial
                label: "Weight (kg)"
                help: page.bodyHelp
                value: page.val("weight_kg")
                inputMethodHints: Qt.ImhFormattedNumbersOnly
                onEditingFinished: if (visible && value !== page.val("weight_kg")) page.apply("weight_kg", value)
            }
            FormTextRow {
                id: weightLbField
                visible: page.imperial
                label: "Weight (lb)"
                help: page.bodyHelp
                value: page.weightLb()
                inputMethodHints: Qt.ImhFormattedNumbersOnly
                onEditingFinished: if (visible && value !== page.weightLb()) page.applyWeightImperial(value)
            }
            FormCard.FormDelegateSeparator {}
            FormTextRow {
                id: ageField
                label: "Age (years)"
                help: page.bodyHelp
                value: page.val("age")
                inputMethodHints: Qt.ImhDigitsOnly
                onEditingFinished: if (value !== page.val("age")) page.apply("age", value)
            }
            FormCard.FormDelegateSeparator {}
            FormOptionRow {
                text: "Sex"
                help: page.bodyHelp
                value: page.label(page.genderOptions[page.comboIndex(page.genderOptions, "gender")])
                onClicked: page.pick(text, "gender", page.genderOptions)
            }
            FormCard.FormDelegateSeparator {}
            FormOptionRow {
                text: "Units"
                // The daemon sends weather in this unit too (there is no separate weather setting).
                description: "Metric or imperial units on the watch"
                help: "Distances on the watch; also the temperature unit for weather and, when Wind speed is Automatic, the wind unit."
                value: page.label(page.unitOptions[page.comboIndex(page.unitOptions, "units")])
                onClicked: page.pick(text, "units", page.unitOptions)
            }
        }

        // --- Tracking -----------------------------------------------------
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp
            title: "Tracking"
        }
        FormCard.FormCard {
            visible: StoandlClient.daemonUp

            FormSwitchRow {
                text: "Activity tracking"
                description: "Steps, distance, calories and active minutes"
                help: "Counts steps and detects walks, runs and sleep. Off saves a little battery but the Health tab stays empty."
                checked: page.boolVal("tracking")
                onToggled: page.apply("tracking", checked ? "on" : "off")
            }
            FormCard.FormDelegateSeparator {}
            FormSwitchRow {
                text: "Activity insights"
                description: "\"Time to move\" and daily-summary cards on the watch"
                help: "Short cards on the watch."
                checked: page.boolVal("activity_insights")
                onToggled: page.apply("activity_insights", checked ? "on" : "off")
            }
            FormCard.FormDelegateSeparator {}
            FormSwitchRow {
                text: "Sleep insights"
                description: "Sleep-summary cards on the watch"
                help: "Short cards on the watch."
                checked: page.boolVal("sleep_insights")
                onToggled: page.apply("sleep_insights", checked ? "on" : "off")
            }
        }

        // --- Heart rate ---------------------------------------------------
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp
            title: "Heart rate"
        }
        FormCard.FormCard {
            visible: StoandlClient.daemonUp

            FormSwitchRow {
                id: hrmSwitch
                text: "Heart-rate monitor"
                help: "Measures heart rate in the background; uses noticeably more battery than step counting."
                checked: page.boolVal("hrm")
                onToggled: page.apply("hrm", checked ? "on" : "off")
            }
            FormCard.FormDelegateSeparator {}
            FormOptionRow {
                text: "Measurement interval"
                help: "Shorter intervals give finer data and drain faster."
                enabled: hrmSwitch.checked
                value: page.label(page.intervalOptions[page.comboIndex(page.intervalOptions, "hrm_interval", "10min")])
                onClicked: page.pick(text, "hrm_interval", page.intervalOptions, "10min")
            }
            FormCard.FormDelegateSeparator {}
            FormSwitchRow {
                text: "HR during activities"
                description: "Continuously track heart rate during detected walks and runs. Uses more battery."
                enabled: hrmSwitch.checked && page.boolVal("tracking")
                checked: page.boolVal("hrm_activity")
                onToggled: page.apply("hrm_activity", checked ? "on" : "off")
            }
            FormCard.FormDelegateSeparator {}
            FormTextRow {
                label: "Resting HR (bpm)"
                value: page.val("resting_hr")
                inputMethodHints: Qt.ImhDigitsOnly
                onEditingFinished: if (value !== page.val("resting_hr")) page.apply("resting_hr", value)
            }
            FormCard.FormDelegateSeparator {}
            FormTextRow {
                label: "Max HR (bpm)"
                value: page.val("max_hr")
                inputMethodHints: Qt.ImhDigitsOnly
                onEditingFinished: if (value !== page.val("max_hr")) page.apply("max_hr", value)
            }
        }

        FormCard.FormSectionText {
            visible: StoandlClient.daemonUp
            text: "These configure the watch's own fitness tracking and sync to it when connected (a health-capable watch is required). The Health tab shows the data the watch reports back."
        }
    }

    // The picker the option rows open (pick), built on first use.
    Loader {
        id: pickerLoader
        active: false
        sourceComponent: OptionPicker {}
    }
}
