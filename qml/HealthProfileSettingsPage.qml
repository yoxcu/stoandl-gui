import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// The watch's health *profile* — its own activity-tracking configuration (body metrics + tracking
// toggles + HR zones), written to the watch's HealthParams BlobDB via GetHealthProfile / SetHealthProfile.
// This is the WRITE side of health; the Health tab shows the read-only synced data. Applied per field
// and synced to the watch (needs a health-capable watch to take effect).
Kirigami.ScrollablePage {
    id: page
    objectName: "healthProfile"
    title: "Health profile"

    property var profile: ({})   // {key: value(string)}

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    function reload() {
        if (!StoandlClient.daemonUp) { page.profile = ({}); return; }
        page.profile = StoandlClient.healthProfile();
    }

    // Set one field, then re-read so the shown values stay authoritative (the daemon may normalise).
    function apply(key, value) {
        var r = StoandlClient.setHealthProfile(key, value);
        if (!r.ok) page.toast((r.tail !== "" ? r.tail : r.kind));
        page.reload();
    }

    function val(key) { return (page.profile || {})[key] || ""; }
    function boolVal(key) { return page.val(key) === "on"; }
    function comboIndex(options, key) { var i = options.indexOf(page.val(key)); return i >= 0 ? i : 0; }

    Connections {
        target: StoandlClient
        function onDaemonUpChanged() { if (StoandlClient.daemonUp) page.reload(); }
    }

    Component.onCompleted: page.reload()

    readonly property var intervalOptions: ["10min", "30min", "1h", "off"]
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
            FormCard.FormTextFieldDelegate {
                id: heightCmField
                visible: !page.imperial
                label: "Height (cm)"
                text: page.val("height_cm")
                inputMethodHints: Qt.ImhDigitsOnly
                onEditingFinished: if (visible && text !== page.val("height_cm")) page.apply("height_cm", text)
            }
            FormCard.FormTextFieldDelegate {
                id: heightFtField
                visible: page.imperial
                label: "Height (ft)"
                text: page.heightFeet()
                inputMethodHints: Qt.ImhDigitsOnly
                onEditingFinished: if (visible && text !== page.heightFeet()) page.applyHeightImperial(text, heightInField.text)
            }
            FormCard.FormDelegateSeparator { visible: page.imperial }
            FormCard.FormTextFieldDelegate {
                id: heightInField
                visible: page.imperial
                label: "Height (in)"
                text: page.heightInches()
                inputMethodHints: Qt.ImhFormattedNumbersOnly
                onEditingFinished: if (visible && text !== page.heightInches()) page.applyHeightImperial(heightFtField.text, text)
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormTextFieldDelegate {
                id: weightKgField
                visible: !page.imperial
                label: "Weight (kg)"
                text: page.val("weight_kg")
                inputMethodHints: Qt.ImhFormattedNumbersOnly
                onEditingFinished: if (visible && text !== page.val("weight_kg")) page.apply("weight_kg", text)
            }
            FormCard.FormTextFieldDelegate {
                id: weightLbField
                visible: page.imperial
                label: "Weight (lb)"
                text: page.weightLb()
                inputMethodHints: Qt.ImhFormattedNumbersOnly
                onEditingFinished: if (visible && text !== page.weightLb()) page.applyWeightImperial(text)
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormTextFieldDelegate {
                id: ageField
                label: "Age (years)"
                text: page.val("age")
                inputMethodHints: Qt.ImhDigitsOnly
                onEditingFinished: if (text !== page.val("age")) page.apply("age", text)
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormComboBoxDelegate {
                text: "Sex"
                model: page.genderOptions
                currentIndex: page.comboIndex(page.genderOptions, "gender")
                onActivated: page.apply("gender", currentValue)
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormComboBoxDelegate {
                text: "Units"
                model: page.unitOptions
                currentIndex: page.comboIndex(page.unitOptions, "units")
                onActivated: page.apply("units", currentValue)
            }
        }

        // --- Tracking -----------------------------------------------------
        FormCard.FormHeader {
            visible: StoandlClient.daemonUp
            title: "Tracking"
        }
        FormCard.FormCard {
            visible: StoandlClient.daemonUp

            FormCard.FormSwitchDelegate {
                text: "Activity tracking"
                description: "Steps, distance, calories and active minutes"
                checked: page.boolVal("tracking")
                onToggled: page.apply("tracking", checked ? "on" : "off")
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormSwitchDelegate {
                text: "Activity insights"
                description: "\"Time to move\" and daily-summary cards on the watch"
                checked: page.boolVal("activity_insights")
                onToggled: page.apply("activity_insights", checked ? "on" : "off")
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormSwitchDelegate {
                text: "Sleep insights"
                description: "Sleep-summary cards on the watch"
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

            FormCard.FormSwitchDelegate {
                id: hrmSwitch
                text: "Heart-rate monitor"
                checked: page.boolVal("hrm")
                onToggled: page.apply("hrm", checked ? "on" : "off")
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormComboBoxDelegate {
                text: "Measurement interval"
                enabled: hrmSwitch.checked
                model: page.intervalOptions
                currentIndex: page.comboIndex(page.intervalOptions, "hrm_interval")
                onActivated: page.apply("hrm_interval", currentValue)
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormTextFieldDelegate {
                label: "Resting HR (bpm)"
                text: page.val("resting_hr")
                inputMethodHints: Qt.ImhDigitsOnly
                onEditingFinished: if (text !== page.val("resting_hr")) page.apply("resting_hr", text)
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormTextFieldDelegate {
                label: "Max HR (bpm)"
                text: page.val("max_hr")
                inputMethodHints: Qt.ImhDigitsOnly
                onEditingFinished: if (text !== page.val("max_hr")) page.apply("max_hr", text)
            }
        }

        FormCard.FormSectionText {
            visible: StoandlClient.daemonUp
            text: "These configure the watch's own fitness tracking and sync to it when connected (a health-capable watch is required). The Health tab shows the data the watch reports back."
        }
    }
}
