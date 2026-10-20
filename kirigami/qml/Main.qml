import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.stoandl.gui

Kirigami.ApplicationWindow {
    id: root

    title: "stoandl"

    // A phone's window is the screen, whatever its size: only the desktop keeps a usable minimum.
    minimumWidth: Kirigami.Settings.isMobile ? 0 : Kirigami.Units.gridUnit * 22
    minimumHeight: Kirigami.Settings.isMobile ? 0 : Kirigami.Units.gridUnit * 30
    width: StoandlClient.smokeSize.width > 0 ? StoandlClient.smokeSize.width : Kirigami.Units.gridUnit * 30
    height: StoandlClient.smokeSize.height > 0 ? StoandlClient.smokeSize.height : Kirigami.Units.gridUnit * 48

    // A dialog's width: `units` grid units, but never wider than the window (a phone held upright).
    function dialogWidth(units) { return Math.min(Kirigami.Units.gridUnit * units, root.width - Kirigami.Units.gridUnit * 2); }

    // Which destination is showing. Watch (0) is the launch view.
    property int currentTab: 0

    // 5 destinations -> Kirigami.NavigationTabBar (KDE HIG: <=5 = tabs, not a drawer).
    // Watch · Health · Apps · Notifications · Settings.
    readonly property var pageComponents: [
        null, healthComponent, appsComponent, notificationsComponent, settingsComponent
    ]

    Component { id: healthComponent;        HealthPage {} }
    Component { id: appsComponent;          AppsPage {} }
    Component { id: notificationsComponent; NotificationsPage {} }
    Component { id: settingsComponent;      SettingsPage {} }

    // The tab pages are built on their first visit and then kept: a tab switch used to build the page
    // again and repeat its loads. A kept page waits in tabPark while another tab shows (PageRow puts an
    // item it didn't create back under its own parent instead of destroying it), is invisible there,
    // and refreshes through its refreshOnShow() after the frame that shows it again.
    property var tabPages: [watchPage, null, null, null, null]
    Item {
        id: tabPark
        visible: false
        WatchPage { id: watchPage }
    }

    // Push a sub-page created here. Kirigami's push(Component) creates the page with a QtObject parent, and
    // Qt warns "Created graphical object was not placed in the graphics scene" for every page. Created
    // without a parent instead, the page is held in pushedPages until PageRow removes it (a back
    // navigation, a tab switch) and destroyed once its slide-out is over, rather than whenever the
    // garbage collector runs (until then it would still follow the daemon's signals). Destroyed at once,
    // the form rows of the page sliding out loop on their background colour.
    property var pushedPages: []
    function pushPage(component, properties) {
        var p = component.createObject(null, properties || {});
        root.pushedPages.push(p);
        return pageStack.push(p);
    }
    Connections {
        target: root.pageStack
        function onPageRemoved(page) {
            var i = root.pushedPages.indexOf(page);
            if (i < 0)
                return;
            root.pushedPages.splice(i, 1);
            page.destroy(Kirigami.Units.humanMoment);
        }
    }

    function showTab(index) {
        // Re-tapping the active tab returns to its root (pops any pushed sub-page, e.g. a Settings
        // detail). Switching tabs first pops sub-pages, then swaps the root page in place.
        if (index === currentTab) {
            while (pageStack.depth > 1)
                pageStack.pop();
            return;
        }
        currentTab = index;
        while (pageStack.depth > 1)
            pageStack.pop();
        var kept = tabPages[index];
        if (!kept)
            tabPages[index] = pageComponents[index].createObject(tabPark);   // loads in its onCompleted
        pageStack.replace(tabPages[index]);
        if (kept)
            root.shownPage = kept;
    }

    // A kept tab page that came back, until the frame that shows it (the timer covers a window that
    // doesn't render).
    property Item shownPage: null
    function refreshShownPage() {
        var p = root.shownPage;
        root.shownPage = null;
        if (p && p.visible && typeof p.refreshOnShow === "function")
            p.refreshOnShow();
    }
    Connections {
        target: root
        enabled: root.shownPage !== null
        function onFrameSwapped() { Qt.callLater(root.refreshShownPage); }
    }
    Timer {
        running: root.shownPage !== null
        interval: 500
        onTriggered: root.refreshShownPage()
    }

    // Smoke harness: run fn once no asynchronous read or watch task is in flight and nothing is being created
    // asynchronously, so a page's smokeExercise() sees the data its loads fetch (they no longer block)
    // and the rows built from it. Queued in order; checked every 50 ms, one fn per check, so the D-Bus
    // signals a fn's calls cause (ConfigChanged …) are dispatched, and their reads started, before the
    // next one looks.
    // Depth first: what a running fn queues runs before the rest of the queue, so a page's walk (and what
    // its hooks queue in turn) ends before the next step, which may pop that page.
    property var smokeQueue: []
    property int smokeInsertAt: -1
    function smokeWhenIdle(fn) {
        if (root.smokeInsertAt >= 0)
            root.smokeQueue.splice(root.smokeInsertAt++, 0, fn);
        else
            root.smokeQueue.push(fn);
        smokeIdleTimer.start();
    }
    Timer {
        id: smokeIdleTimer
        interval: 50
        repeat: true
        onTriggered: {
            if (root.smokeQueue.length > 0 && StoandlClient.callsInFlight === 0
                && Object.keys(StoandlClient.tasks).length === 0 && StoandlClient.incubatingObjects() === 0) {
                var fn = root.smokeQueue.shift();
                root.smokeInsertAt = 0;
                fn();
                root.smokeInsertAt = -1;
            }
            if (root.smokeQueue.length === 0)
                stop();
        }
    }

    // Headless verification harness (sandbox only, gated on STOANDL_SMOKE_MS). Steps through every
    // destination one per tick, deep-exercises the Settings sub-pages, then quits — so an offscreen run
    // against the mock proves QML → StoandlClient → D-Bus → render end-to-end and self-terminates.
    Timer {
        id: smokeTimer
        property int step: 0
        running: StoandlClient.smokeMs > 0
        interval: Math.max(1, StoandlClient.smokeMs)
        repeat: true
        onTriggered: {
            // Daemon down: press "Start daemon" once, as DaemonPlaceholder's action does (a failed
            // start is logged by StoandlClient and toasted by the handler below).
            if (smokeTimer.step === 0 && !StoandlClient.daemonUp) {
                console.log("stoandl-smoke: daemon down (" + StoandlClient.daemonState + "), pressing Start daemon");
                StoandlClient.startDaemon();
            }
            if (smokeTimer.step === 0)
                console.log("stoandl-smoke: window " + root.width + "x" + root.height + " mobile=" + Kirigami.Settings.isMobile);
            // A page's walk can queue more than a tick holds (Settings pushes every sub-page): the next
            // tab, and the quit, wait until it is done, so every exercise runs on its page while it shows.
            if (root.smokeQueue.length > 0)
                return;
            if (smokeTimer.step >= root.pageComponents.length) {
                smokeTimer.running = false;
                // Once every exercise ran and the settings rows are built: destroy the pushed pages now
                // (a pop only animates them away) and quit. (The kept tab pages go back to tabPark.)
                root.smokeWhenIdle(function () {
                    console.log("stoandl-smoke: cycled all " + root.pageComponents.length + " pages, quitting");
                    root.pageStack.clear();
                    Qt.quit();
                });
                return;
            }
            root.showTab(smokeTimer.step);
            console.log("stoandl-smoke: page " + smokeTimer.step);
            var cur = root.pageStack.currentItem;
            if (cur && typeof cur.smokeExercise === "function")
                root.smokeWhenIdle(function () { cur.smokeExercise(); });
            smokeTimer.step += 1;
        }
    }

    // "Start daemon" (DaemonPlaceholder) is async: report a failed start here, once, rather than
    // from each page's placeholder. The message is systemctl's own first stderr line.
    // A watch task's result is reported here too, whichever page started it (the page may be gone).
    Connections {
        target: StoandlClient
        function onDaemonStartFailed(message) {
            root.showPassiveNotification("Could not start stoandl: " + message, "long");
        }
        function onTaskFinished(kind, r) { root.reportTask(kind, r); }
    }

    // The two ways notifications stop reaching the watch on purpose, and their fixes, for the Alerts
    // and Watch tabs: notification.forward off, and the temporary mute of every app.
    function turnOnForwarding() {
        var r = StoandlClient.setConfig("notification.forward", "true");
        root.showPassiveNotification(r.ok ? "Notifications are forwarded again"
                                          : "Could not turn forwarding on: " + (r.tail || r.kind));
    }
    function resumeNotifications() {
        var r = StoandlClient.notifSetMuteAll("never");
        root.showPassiveNotification(r.ok ? r.tail : "Could not resume: " + (r.tail || r.kind));
    }
    // When a mute ends: "14:30" today, "Tue 21 Oct 14:30" later (epoch seconds).
    function formatUntil(epoch) {
        var d = new Date(epoch * 1000);
        return new Date().toDateString() === d.toDateString() ? Qt.formatTime(d, "HH:mm")
                                                              : d.toLocaleString(Qt.locale(), "ddd d MMM HH:mm");
    }

    // Open a file the daemon saved (or its folder), saying so when this GUI can't reach it.
    function openSaved(path, folder) {
        if (!(folder ? StoandlClient.openFolderOf(path) : StoandlClient.openFile(path)))
            root.showPassiveNotification("Could not open " + path + " from this app", "long");
    }

    function reportTask(kind, r) {
        var why = r.tail || r.kind;
        if (StoandlClient.smokeMs > 0)
            console.log("stoandl-smoke: task " + kind + " -> " + r.kind + " " + (r.path || r.tail));
        if (kind === "sideload") {
            root.showPassiveNotification(r.ok ? (r.tail || "Installed") : "Install failed: " + why, r.ok ? "short" : "long");
        } else if (kind === "screenshot") {
            if (r.ok) {
                screenshotLoader.active = true;
                screenshotLoader.item.show(r);
                if (StoandlClient.smokeMs > 0) {
                    console.log("stoandl-smoke: screenshot preview " + r.width + "x" + r.height
                                + " shown=" + screenshotLoader.item.visible);
                    root.smokeWhenIdle(function () { screenshotLoader.item.close(); });
                }
            } else {
                root.showPassiveNotification("Screenshot: " + why, "long");
            }
        } else if (r.ok) {
            root.showPassiveNotification((kind === "logs" ? "Watch logs saved: " : "Core dump saved: ") + r.path, "long",
                                         "Open folder", function () { root.openSaved(r.path, true); });
        } else {
            root.showPassiveNotification(r.kind === "none" ? "No core dump available"
                                         : (kind === "logs" ? "Watch logs: " : "Core dump: ") + why, "long");
        }
    }

    // Ask before an action that can't be put back (ConfirmDialog, built on first use): `onConfirm` runs on
    // the action's button, nothing on Cancel. Actions that can be undone act at once with Undo on the toast.
    function confirm(heading, text, actionText, actionIcon, onConfirm) {
        confirmLoader.active = true;
        confirmLoader.item.ask(heading, text, actionText, actionIcon, onConfirm);
        return confirmLoader.item;
    }
    Loader {
        id: confirmLoader
        active: false
        sourceComponent: ConfirmDialog {}
    }

    // The screenshot preview (Open / Open folder / Take another), built on the first screenshot.
    Loader {
        id: screenshotLoader
        active: false
        sourceComponent: ScreenshotDialog {}
    }

    // One thin bar along the top while someone waits on the daemon: a run() or fetch() in flight, or a
    // watch task this GUI started. Only after a moment, so a quick answer doesn't flash it.
    QQC2.ProgressBar {
        id: busyBar
        readonly property bool waiting: StoandlClient.userCallsInFlight > 0 || Object.keys(StoandlClient.tasks).length > 0
        z: 1000
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: Kirigami.Units.smallSpacing
        indeterminate: true
        visible: waiting && busyDelay.elapsed
        Accessible.name: "Waiting for stoandl"
        Timer {
            id: busyDelay
            property bool elapsed: false
            interval: 300
            running: busyBar.waiting
            onRunningChanged: if (running) elapsed = false
            onTriggered: elapsed = true
        }
    }

    // No global drawer — navigation is the (responsive) tab bar. Putting the
    // NavigationTabBar in the window footer makes it sit BELOW content on mobile
    // and relocate ABOVE content on desktop, per the KDE HIG.
    globalDrawer: null
    contextDrawer: null

    // The kept WatchPage instance (declared in tabPark), not a Component: assigning a *Component* to
    // initialPage makes Kirigami createObject() it with a transient null parent → Qt6 warns "QML
    // WatchPage: Created graphical object was not placed in the graphics scene". A page that already
    // has a parent in the window tree is silent.
    pageStack.initialPage: watchPage

    footer: Kirigami.NavigationTabBar {
        id: tabBar
        // Hide nav entirely when the daemon is down — nothing works without it
        // (handoff §5 states; CLAUDE.md daemon-down rule).
        visible: StoandlClient.daemonUp
        height: visible ? implicitHeight : 0
        actions: [
            Kirigami.Action {
                icon.name: "chronometer-symbolic"
                text: "Watch"
                checkable: true
                checked: root.currentTab === 0
                onTriggered: root.showTab(0)
            },
            Kirigami.Action {
                // Ship our own monochrome heart: every Breeze heart (love/emblem-favorite)
                // resolves to the colored Amarok "love" icon, which NavigationTabBar renders
                // as-is. Ours uses the ColorScheme-Text stylesheet so KDE recolours it.
                icon.name: "stoandl-heart-symbolic"
                text: "Health"
                checkable: true
                checked: root.currentTab === 1
                onTriggered: root.showTab(1)
            },
            Kirigami.Action {
                icon.name: "view-list-icons-symbolic"
                text: "Apps"
                checkable: true
                checked: root.currentTab === 2
                onTriggered: root.showTab(2)
            },
            Kirigami.Action {
                icon.name: "notifications-symbolic"
                text: "Alerts"   // short label so the tab doesn't wrap on narrow widths
                checkable: true
                checked: root.currentTab === 3
                onTriggered: root.showTab(3)
            },
            Kirigami.Action {
                icon.name: "settings-configure-symbolic"
                text: "Settings"
                checkable: true
                checked: root.currentTab === 4
                onTriggered: root.showTab(4)
            }
        ]
    }
}
