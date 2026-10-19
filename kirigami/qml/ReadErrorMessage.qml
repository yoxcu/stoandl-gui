import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.stoandl.gui

// "Couldn't read …: <why>" while one of a page's list reads failed on D-Bus (StoandlClient.readErrors), so
// the page doesn't pass an unanswered call off as an empty list. `failed` lets the page hide its "nothing
// here yet" placeholder meanwhile. Gone with the next read that succeeds.
Kirigami.InlineMessage {
    id: msg

    /** The typed reads the page shows (their readSpec names, e.g. ["notifList", "notifListFilters"]). */
    property var reads: []
    /** Lower-case noun for the message: "Couldn't read the <what>". */
    property string what: "list"

    readonly property string why: {
        var errors = StoandlClient.readErrors;
        for (var i = 0; i < msg.reads.length; ++i) {
            if (errors[msg.reads[i]] !== undefined)
                return errors[msg.reads[i]];
        }
        return "";
    }
    readonly property bool failed: StoandlClient.daemonUp && msg.why !== ""

    visible: msg.failed
    Layout.topMargin: Kirigami.Units.largeSpacing
    Layout.leftMargin: Kirigami.Units.largeSpacing
    Layout.rightMargin: Kirigami.Units.largeSpacing
    type: Kirigami.MessageType.Error
    text: "Couldn't read the " + msg.what + ": " + msg.why
}
