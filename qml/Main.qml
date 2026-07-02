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
        watchComponent, healthComponent, appsComponent, notificationsComponent, settingsComponent
    ]

    Component { id: watchComponent;         WatchPage {} }
    Component { id: healthComponent;        HealthPage {} }
    Component { id: appsComponent;          AppsPage {} }
    Component { id: notificationsComponent; NotificationsPage {} }
    Component { id: settingsComponent;      SettingsPage {} }

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
        pageStack.replace(pageComponents[index]);
    }

    // No global drawer — navigation is the (responsive) tab bar. Putting the
    // NavigationTabBar in the window footer makes it sit BELOW content on mobile
    // and relocate ABOVE content on desktop, per the KDE HIG.
    globalDrawer: null
    contextDrawer: null

    // Inline initial page (not the watchComponent Component). Assigning a *Component* to initialPage
    // makes Kirigami createObject() it with a transient null parent → Qt6 warns "QML WatchPage: Created
    // graphical object was not placed in the graphics scene" (verified: deferring via onCompleted/
    // Qt.callLater doesn't help — it's the Component indirection, not the timing). An inline page is
    // parented into the window tree at construction, so it's silent. watchComponent is still used by
    // showTab()'s replace() for tab navigation.
    pageStack.initialPage: WatchPage {}

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
                text: "Notifications"
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
