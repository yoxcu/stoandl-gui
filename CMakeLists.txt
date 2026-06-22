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

qt_add_executable(stoandl-gui
    src/main.cpp
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
