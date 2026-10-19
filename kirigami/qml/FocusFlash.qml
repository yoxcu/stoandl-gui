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

    // After the frame that laid the row out (a hit's page builds every row at once, so the rows above it
    // have their final heights by then).
    function reveal(row) {
        Qt.callLater(function () {
            if (!row || !root.flickable) return;
            var f = root.flickable;
            var y = row.mapToItem(f.contentItem, 0, 0).y - Kirigami.Units.gridUnit * 2;
            f.contentY = Math.max(0, Math.min(y, f.contentHeight - f.height));
            flash.parent = row;
            anim.restart();
            if (StoandlClient.smokeMs > 0)
                console.log("stoandl-smoke: revealed " + (row.modelData.key || row.modelData.id) + " at y=" + Math.round(f.contentY));
        });
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
        }
    }
}
