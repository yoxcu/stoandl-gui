cmake_minimum_required(VERSION 3.21)

project(stoandl-gui VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# Qt6 is the only thing we link against. Kirigami + KirigamiAddons are pure-QML
# runtime modules (the qml6-module-org-kde-* packages); we never link them in C++,
# so they are NOT find_package()'d here — only required at run time.
find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Widgets Qml Quick QuickControls2 DBus)

qt_standard_project_setup(REQUIRES 6.5)

include(GNUInstallDirs)

qt_add_executable(stoandl-gui
    src/main.cpp
)

# Embed a subset of the app-icon PNGs so the window icon is present even when the
# app runs uninstalled from build/. At runtime an installed hicolor theme icon is
# preferred (via QIcon::fromTheme) and this resource is only the fallback — see
# src/main.cpp. BASE strips the on-disk prefix so the aliases are :/icons/<size>/apps/…
qt_add_resources(stoandl-gui "appicon"
    PREFIX "/icons"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/data/icons/hicolor"
    FILES
        data/icons/hicolor/16x16/apps/de.yoxcu.stoandl.gui.png
        data/icons/hicolor/24x24/apps/de.yoxcu.stoandl.gui.png
        data/icons/hicolor/32x32/apps/de.yoxcu.stoandl.gui.png
        data/icons/hicolor/48x48/apps/de.yoxcu.stoandl.gui.png
        data/icons/hicolor/64x64/apps/de.yoxcu.stoandl.gui.png
        data/icons/hicolor/128x128/apps/de.yoxcu.stoandl.gui.png
        data/icons/hicolor/256x256/apps/de.yoxcu.stoandl.gui.png
)

qt_add_qml_module(stoandl-gui
    URI org.stoandl.gui
    VERSION 1.0
    QML_FILES
        qml/Main.qml
        qml/StatusChip.qml
        qml/DaemonPlaceholder.qml
        qml/WatchPage.qml
        qml/WatchDetailsDialog.qml
        qml/HealthPage.qml
        qml/AppsPage.qml
        qml/NotificationsPage.qml
        qml/SettingsPage.qml
        qml/SyncSettingsPage.qml
        qml/CalendarsSettingsPage.qml
        qml/WatchSettingsPage.qml
        qml/GeneralSettingsPage.qml
        qml/BackupSettingsPage.qml
    SOURCES
        src/StoandlClient.h
        src/StoandlClient.cpp
)

# So the generated QML type-registration's `#if __has_include(<StoandlClient.h>)`
# resolves — the header lives in src/.
target_include_directories(stoandl-gui PRIVATE src)

target_link_libraries(stoandl-gui PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Qml
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::DBus
)

install(TARGETS stoandl-gui
    BUNDLE  DESTINATION .
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

# Desktop integration: launcher entry + AppStream metainfo + hicolor icon theme tree
# (see data/README.md). On Wayland the window icon comes from the .desktop match, so
# these MUST be installed for the icon to appear — running from build/ shows none.
install(FILES data/de.yoxcu.stoandl.gui.desktop
    DESTINATION ${CMAKE_INSTALL_DATADIR}/applications
)
install(FILES data/de.yoxcu.stoandl.gui.metainfo.xml
    DESTINATION ${CMAKE_INSTALL_DATADIR}/metainfo
)
install(DIRECTORY data/icons/hicolor
    DESTINATION ${CMAKE_INSTALL_DATADIR}/icons
    FILES_MATCHING PATTERN "*.png" PATTERN "*.svg"
)
