import QtQuick
import org.kde.kirigami as Kirigami
import org.stoandl.gui

// Shared "daemon not running" empty state, worded by StoandlClient.daemonState. The daemon is NOT
// D-Bus-activated, so where systemd can start it here we offer "Start daemon"; a Flatpak (no access to the
// host's systemd), a system without systemctl and a missing unit get the command to run instead.
Kirigami.PlaceholderMessage {
    id: placeholder

    readonly property string daemonState: StoandlClient.daemonState
    readonly property bool canStart: daemonState === "stopped" || daemonState === "failed" || daemonState === "startlimit"

    icon.name: daemonState === "starting" ? "chronometer-symbolic" : "network-disconnect-symbolic"
    text: daemonState === "starting" ? "stoandl is starting"
        : daemonState === "notinstalled" ? "stoandl isn't installed"
        : daemonState === "startlimit" ? "stoandl stopped after crashing repeatedly"
        : daemonState === "failed" ? "stoandl stopped with an error"
        : "stoandl isn't running"
    explanation: daemonState === "starting" ? "It is getting ready to talk to your watch; this page fills in by itself."
        : daemonState === "flatpak" ? "Start it on this computer with: systemctl --user start stoandl (OpenRC: rc-service stoandl start)"
        : daemonState === "nosystemd" ? "Start it with: rc-service stoandl start"
        : daemonState === "notinstalled" ? "This app needs the stoandl service: install the stoandl package (with stoandl-systemd), then start it."
        : daemonState === "startlimit" ? "systemd gave up restarting it. Its log is /tmp/stoandl.log; Start daemon tries again."
        : daemonState === "failed" ? "Its log is /tmp/stoandl.log."
        : "The background service that talks to your Pebble isn't running."
    helpfulAction: Kirigami.Action {
        icon.name: "media-playback-start-symbolic"
        text: "Start daemon"
        enabled: placeholder.canStart
        visible: placeholder.canStart
        // Async (reset-failed, then start): a failure arrives as daemonStartFailed, which Main.qml
        // reports once — this placeholder is instantiated on every page.
        onTriggered: {
            StoandlClient.startDaemon();
            applicationWindow().showPassiveNotification("Starting stoandl…");
        }
    }
}
