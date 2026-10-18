import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// City search for Settings → Weather (SearchWeatherPlace / AddWeatherLocation): type a name, pick a
// result, and the daemon adds it to weather.locations. The lookup is an Open-Meteo request, so it runs
// only on Enter or the Search button, and the daemon refuses it unless weather.place_search is on.
// `changed()` asks the page to re-read its config so the Locations row shows the new entry.
// The page passes weather.place_search in as `searchOn` from the config it already holds.
ColumnLayout {
    id: card
    spacing: 0

    signal changed()

    /** weather.place_search, from the page's config (no GetConfig of its own). */
    property bool searchOn: false
    property var places: []
    property string message: ""

    function toast(msg) { applicationWindow().showPassiveNotification(msg); }

    function search() {
        var q = nameRow.value.trim();
        if (q === "") return;
        var r = StoandlClient.searchWeatherPlace(q);
        card.places = r.places || [];
        card.message = r.ok ? "" : (r.tail || r.kind);
    }

    function add(p) {
        var r = StoandlClient.addWeatherLocation(p.name, p.lat, p.lon);
        card.toast(r.tail || r.kind);
        if (r.ok) {
            card.places = [];
            nameRow.value = "";
            card.changed();
        }
    }

    FormCard.FormHeader { title: "Find a location" }

    FormCard.FormCard {
        FormCard.FormTextDelegate {
            visible: !card.searchOn
            text: "Search is off"
            description: "Turn on \"Find locations by name\" above to look cities up by name. "
                + "The name you type is sent to Open-Meteo's geocoder."
            icon.name: "find-location-symbolic"
        }

        FormTextRow {
            id: nameRow
            visible: card.searchOn
            label: "City"
            placeholderText: "e.g. Berlin"
        }

        // Enter searches; leaving the field doesn't (that would be a web request nobody asked for).
        Connections {
            target: nameRow.field
            function onAccepted() { card.search(); }
        }

        FormCard.FormButtonDelegate {
            visible: card.searchOn
            enabled: nameRow.value.trim() !== ""
            text: "Search"
            icon.name: "search-symbolic"
            onClicked: card.search()
        }

        FormCard.FormTextDelegate {
            visible: card.searchOn && card.message !== ""
            text: card.message
        }

        Repeater {
            model: card.searchOn ? card.places : []
            delegate: FormCard.AbstractFormDelegate {
                id: row
                required property var modelData
                background: null
                hoverEnabled: false
                Accessible.name: modelData.name

                contentItem: RowLayout {
                    spacing: Kirigami.Units.largeSpacing

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        QQC2.Label {
                            Layout.fillWidth: true
                            text: row.modelData.name
                            elide: Text.ElideRight
                        }
                        QQC2.Label {
                            Layout.fillWidth: true
                            text: [row.modelData.region, row.modelData.country].filter(s => s !== "").join(", ")
                                + "  (" + row.modelData.lat + ", " + row.modelData.lon + ")"
                            font: Kirigami.Theme.smallFont
                            color: Kirigami.Theme.disabledTextColor
                            elide: Text.ElideRight
                        }
                    }

                    QQC2.Button {
                        text: "Add"
                        icon.name: "list-add-symbolic"
                        onClicked: card.add(row.modelData)
                    }
                }
            }
        }
    }
}
