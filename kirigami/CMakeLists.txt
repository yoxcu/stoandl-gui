cmake_minimum_required(VERSION 3.21)

project(stoandl-gui VERSION 0.3.0 LANGUAGES CXX)

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
    src/SingleInstance.h
    src/SingleInstance.cpp
)

# Embed a subset of the app-icon PNGs so the window icon is present even when the
# app runs uninstalled from build/. At runtime an installed hicolor theme icon is
# preferred (via QIcon::fromTheme) and this resource is only the fallback — see
# src/main.cpp. BASE strips the on-disk prefix so the aliases are :/icons/<size>/apps/…
# data/ is a SHARED tree at the repo root (one level up from this kirigami/ subdir).
qt_add_resources(stoandl-gui "appicon"
    PREFIX "/icons"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/../data/icons/hicolor"
    FILES
        ../data/icons/hicolor/16x16/apps/de.yoxcu.stoandl.gui.png
        ../data/icons/hicolor/24x24/apps/de.yoxcu.stoandl.gui.png
        ../data/icons/hicolor/32x32/apps/de.yoxcu.stoandl.gui.png
        ../data/icons/hicolor/48x48/apps/de.yoxcu.stoandl.gui.png
        ../data/icons/hicolor/64x64/apps/de.yoxcu.stoandl.gui.png
        ../data/icons/hicolor/128x128/apps/de.yoxcu.stoandl.gui.png
        ../data/icons/hicolor/256x256/apps/de.yoxcu.stoandl.gui.png
)

# Our own named theme icons (the monochrome heart). Installed into the hicolor tree
# below (found via the icon theme + recoloured by KDE when installed / in the Flatpak);
# also embedded here so `icon.name` resolves when running uninstalled from build/ —
# main.cpp adds ":/fallback-icons" to QIcon::fallbackSearchPaths.
qt_add_resources(stoandl-gui "fallback_icons"
    PREFIX "/fallback-icons"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/../data/icons/hicolor/scalable/actions"
    FILES
        ../data/icons/hicolor/scalable/actions/stoandl-heart-symbolic.svg
)

qt_add_qml_module(stoandl-gui
    URI org.stoandl.gui
    VERSION 1.0
    QML_FILES
        qml/Main.qml
        qml/StatusChip.qml
        qml/ActionChip.qml
        qml/FormTextRow.qml
        qml/FormSpinRow.qml
        qml/FormListRow.qml
        qml/FormOptionRow.qml
        qml/FormSwitchRow.qml
        qml/RowHelp.qml
        qml/OptionPicker.qml
        qml/ConfList.js
        qml/StableRows.js
        qml/DaemonPlaceholder.qml
        qml/WatchPage.qml
        qml/WatchDetailsDialog.qml
        qml/BatteryPage.qml
        qml/HealthPage.qml
        qml/AppsPage.qml
        qml/AppPermissionsDialog.qml
        qml/NotificationsPage.qml
        qml/WatchCardPreview.qml
        qml/SettingsPage.qml
        qml/CalendarsSettingsPage.qml
        qml/WatchSettingsPage.qml
        qml/SchemaSettingsPage.qml
        qml/SchemaSections.qml
        qml/RestartMessage.qml
        qml/FocusFlash.qml
        qml/AboutSettingsPage.qml
        qml/ForwardingBanner.qml
        qml/ReadErrorMessage.qml
        qml/ScreenshotDialog.qml
        qml/SaveFileDialog.qml
        qml/VoiceModelsCard.qml
        qml/WeatherSearchCard.qml
        qml/HealthProfileSettingsPage.qml
        qml/BackupSettingsPage.qml
        qml/DebugSettingsPage.qml
        qml/HeartbeatPage.qml
    SOURCES
        src/StoandlClient.h
        src/StoandlClient.cpp
)

# So the generated QML type-registration's `#if __has_include(<StoandlClient.h>)`
# resolves — the header lives in src/.
target_include_directories(stoandl-gui PRIVATE src)

# The version Settings → About and the support line show. Packaging passes it (the APKBUILD its pkgver,
# the release CI the tag into the Flatpak manifest). Otherwise `git describe` of this tree's own checkout
# (a development build), and only that one: a release tarball unpacked inside some other repo (the CI
# checkout, an aports tree) would describe that repo. Failing both, the project version above.
set(STOANDL_GUI_VERSION "" CACHE STRING "Version string shown in the GUI (empty: git describe, else the project version)")
set(STOANDL_GUI_SHOWN_VERSION "${STOANDL_GUI_VERSION}")
find_package(Git QUIET)
if(STOANDL_GUI_SHOWN_VERSION STREQUAL "" AND GIT_FOUND)
    execute_process(COMMAND "${GIT_EXECUTABLE}" rev-parse --show-toplevel
                    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
                    OUTPUT_VARIABLE STOANDL_GUI_GIT_TOP OUTPUT_STRIP_TRAILING_WHITESPACE
                    ERROR_QUIET RESULT_VARIABLE STOANDL_GUI_GIT_RESULT)
    get_filename_component(STOANDL_GUI_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." REALPATH)
    if(STOANDL_GUI_GIT_RESULT EQUAL 0 AND NOT STOANDL_GUI_GIT_TOP STREQUAL "")
        get_filename_component(STOANDL_GUI_GIT_TOP "${STOANDL_GUI_GIT_TOP}" REALPATH)
    endif()
    if(STOANDL_GUI_GIT_RESULT EQUAL 0 AND STOANDL_GUI_GIT_TOP STREQUAL STOANDL_GUI_ROOT)
        execute_process(COMMAND "${GIT_EXECUTABLE}" describe --tags --always --dirty
                        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
                        OUTPUT_VARIABLE STOANDL_GUI_SHOWN_VERSION OUTPUT_STRIP_TRAILING_WHITESPACE
                        ERROR_QUIET)
    endif()
endif()
if(STOANDL_GUI_SHOWN_VERSION STREQUAL "")
    set(STOANDL_GUI_SHOWN_VERSION "${PROJECT_VERSION}")
endif()
target_compile_definitions(stoandl-gui PRIVATE STOANDL_GUI_VERSION="${STOANDL_GUI_SHOWN_VERSION}")

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
install(FILES ../data/de.yoxcu.stoandl.gui.desktop
    DESTINATION ${CMAKE_INSTALL_DATADIR}/applications
)
install(FILES ../data/de.yoxcu.stoandl.gui.metainfo.xml
    DESTINATION ${CMAKE_INSTALL_DATADIR}/metainfo
)
install(DIRECTORY ../data/icons/hicolor
    DESTINATION ${CMAKE_INSTALL_DATADIR}/icons
    FILES_MATCHING
        PATTERN "*.png"
        PATTERN "*.svg"
)
