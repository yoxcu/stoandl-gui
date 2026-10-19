pragma ComponentBehavior: Bound

import QtQuick
import org.kde.kirigami as Kirigami

// A mock-up of the watch's notification card, for choosing where an app's name goes (notification.app_name
// or an app's override). PebbleOS draws a fixed order — a banner in the app's colour with its icon, then
// Title (bold), Subtitle (the largest bold font), LocationName (a small regular line), Body and a relative
// time — and the host can't change fonts or order, so a placement only decides which line, if any, carries
// the app name. The card is white with black text in either theme, like the watch's screen: those colours
// (and the banner's) depict the watch, not the app's chrome — the exception to "theme colours only".
Rectangle {
    id: card

    // notification.app_name's options: `text` is the label GetConfig reports and SetConfig takes, `value`
    // the placement token (`placement` below, and NotifSetAppName's for an app's override).
    readonly property var placements: [
        { text: "Small line", value: "small" },
        { text: "Subtitle",   value: "subtitle" },
        { text: "Off",        value: "off" }
    ]
    // The token for a label or token (case-insensitive), "" for neither.
    function placementOf(v) {
        var s = String(v || "").toLowerCase();
        for (var i = 0; i < card.placements.length; ++i) {
            if (card.placements[i].value === s || card.placements[i].text.toLowerCase() === s)
                return card.placements[i].value;
        }
        return "";
    }

    property string appName: ""
    // small | subtitle | off, already resolved (an app on "Default" passes the global placement).
    property string placement: "small"
    // The banner colour as a hex; "" = the watch's default, Pebble "Folly".
    property string accent: ""
    property string title: "Family"
    property string body: "Alice: are we still on for tonight?"
    property string time: "now"

    // The daemon's watchFields() (NotificationLayout.kt) for a notification without a subtitle of its own:
    // the app name goes into the slot `placement` names and is left out when it repeats the title, so no
    // line shows twice. The only copy of that rule in this front-end.
    readonly property var lines: {
        var name = card.appName.trim();
        if (name.toLowerCase() === card.title.trim().toLowerCase())
            name = "";
        var out = [{ slot: "title", text: card.title }];
        if (name !== "" && (card.placement === "subtitle" || card.placement === "small"))
            out.push({ slot: card.placement, text: name });
        if (card.body !== "")
            out.push({ slot: "body", text: card.body });
        if (card.time !== "")
            out.push({ slot: "time", text: card.time });
        return out;
    }

    // Each slot's font as the watch draws it on a Time 2: the Gothic size and weight.
    readonly property var slots: ({
        title:    { size: 24, bold: true },
        subtitle: { size: 28, bold: true },
        small:    { size: 18, bold: false },
        body:     { size: 28, bold: false },
        time:     { size: 18, bold: false }
    })
    // The lines as the smoke harness logs them, top to bottom: "title=Family | small=NeoChat | …".
    readonly property string summary: card.lines.map(function (l) { return l.slot + "=" + l.text; }).join(" | ")
    // Pixels per Gothic point: the card stands for the Time 2's 200 px wide screen, and a system font at
    // about 4/5 of Gothic's nominal size (its line height) fits about as many characters on a line.
    readonly property real unit: width / 200 * 0.82
    readonly property color bannerColor: card.accent !== "" ? card.accent : "#FF0055"

    implicitWidth: Kirigami.Units.gridUnit * 11
    implicitHeight: Math.round(implicitWidth * 228 / 200)   // the Time 2's 200 × 228 screen
    radius: Math.round(width * 0.06)
    color: "white"

    // Read as one image: its lines, and where the app name is.
    Accessible.role: Accessible.Graphic
    Accessible.name: "Watch preview: " + card.lines.map(function (l) { return l.text; }).join(", ")
    Accessible.description: card.lines.some(function (l) { return l.slot === "subtitle"; })
                            ? "The app name is the subtitle"
                            : card.lines.some(function (l) { return l.slot === "small"; })
                              ? "The app name is a small line under the title" : "The app name is not on the card"

    Rectangle {
        id: banner
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: Math.round(card.height * 0.17)
        radius: card.radius
        color: card.bannerColor

        // Square off the lower corners: only the card's top corners are round.
        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: parent.radius
            color: parent.color
        }

        Kirigami.Icon {
            anchors.centerIn: parent
            width: Math.round(banner.height * 0.75)
            height: width
            roundToIconSize: false   // scale with the card, not to the next standard icon size
            source: "notifications-symbolic"
            isMask: true
            color: Kirigami.ColorUtils.brightnessForColor(card.bannerColor) === Kirigami.ColorUtils.Light
                   ? "black" : "white"
            Accessible.ignored: true
        }
    }

    Column {
        anchors {
            left: parent.left; right: parent.right; top: banner.bottom; bottom: parent.bottom
            leftMargin: Math.round(card.width * 0.04); rightMargin: Math.round(card.width * 0.04)
            topMargin: Math.round(card.width * 0.02); bottomMargin: Math.round(card.width * 0.02)
        }
        clip: true   // a long card scrolls on the watch; its first screen is what this shows

        Repeater {
            model: card.lines
            delegate: Text {
                required property var modelData
                width: parent.width
                text: modelData.text
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: "black"
                font.family: Kirigami.Theme.defaultFont.family
                font.pixelSize: Math.max(1, Math.round(card.slots[modelData.slot].size * card.unit))
                font.bold: card.slots[modelData.slot].bold
                Accessible.ignored: true   // the card's name reads the lines
            }
        }
    }

    // A theme-tinted frame on top, so the white card stands out on a light page too.
    Rectangle {
        anchors.fill: parent
        radius: card.radius
        color: "transparent"
        border.width: 1
        border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.25)
    }
}
