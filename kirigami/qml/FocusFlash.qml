import QtQuick
import org.kde.kirigami as Kirigami
import org.stoandl.gui

// A settings page's search-hit highlight: reveal(row) scrolls the row into view and fades a highlight
// over it once. The highlight waits here, invisible, between uses.
Item {
    id: root

    /** The page's Flickable (Kirigami.ScrollablePage.flickable). */
    property Flickable flickable: null

    visible: false

    property Item row: null

    // After the frame that laid the row out (a hit's page builds every row and card at once). Content
    // above the row can still change height while it flashes (a card filling in from a D-Bus reply), so
    // until the flash ends the row is scrolled back into view whenever the page's height changes.
    function reveal(row) {
        Qt.callLater(function () {
            if (!row || !root.flickable) return;
            root.row = row;
            root.scrollToRow();
            flash.parent = row;
            anim.restart();
            if (StoandlClient.smokeMs > 0)
                console.log("stoandl-smoke: revealed " + (row.modelData.key || row.modelData.id) + " at y=" + Math.round(root.flickable.contentY));
        });
    }
    function scrollToRow() {
        if (!root.row || !root.flickable) return;
        var f = root.flickable;
        var y = root.row.mapToItem(f.contentItem, 0, 0).y - Kirigami.Units.gridUnit * 2;
        f.contentY = Math.max(0, Math.min(y, f.contentHeight - f.height));
    }

    Connections {
        target: root.flickable
        enabled: anim.running && root.row !== null
        function onContentHeightChanged() { Qt.callLater(root.scrollToRow); }
    }

    Rectangle {
        id: flash
        visible: opacity > 0
        anchors.fill: parent
        color: Kirigami.Theme.highlightColor
        opacity: 0

        SequentialAnimation {
            id: anim
            NumberAnimation { target: flash; property: "opacity"; to: 0.35; duration: Kirigami.Units.shortDuration }
            PauseAnimation { duration: 1200 }
            NumberAnimation { target: flash; property: "opacity"; to: 0; duration: Kirigami.Units.longDuration }
            ScriptAction { script: root.row = null }
        }
    }
}
