import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.stoandl.gui

Kirigami.ApplicationWindow {
    id: root

    title: "stoandl"

    minimumWidth: Kirigami.Units.gridUnit * 22
    minimumHeight: Kirigami.Units.gridUnit * 30
    width: Kirigami.Units.gridUnit * 30
    height: Kirigami.Units.gridUnit * 48

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

    // Smoke harness: run fn once no asynchronous read is in flight and nothing is being created
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
            if (root.smokeQueue.length > 0
                && StoandlClient.callsInFlight === 0 && StoandlClient.incubatingObjects() === 0) {
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
            if (smokeTimer.step >= root.pageComponents.length) {
                // A page's walk can queue more than a tick holds (Settings pushes every sub-page): quit
                // only after it.
                if (root.smokeQueue.length > 0)
                    return;
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
    Connections {
        target: StoandlClient
        function onDaemonStartFailed(message) {
            root.showPassiveNotification("Could not start stoandl: " + message, "long");
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
