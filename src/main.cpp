#include <QApplication>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QIcon>

int main(int argc, char *argv[])
{
    // QApplication (not QGuiApplication) so the org.kde.desktop QtQuick Controls
    // style and Breeze theming work on the convergent desktop target.
    QApplication app(argc, argv);

    QApplication::setOrganizationName(QStringLiteral("stoandl"));
    QApplication::setOrganizationDomain(QStringLiteral("yoxcu.de"));
    QApplication::setApplicationName(QStringLiteral("stoandl-gui"));
    QApplication::setApplicationDisplayName(QStringLiteral("stoandl"));
    // Reverse-DNS app ID under our own domain (yoxcu.de), sibling to the daemon's
    // bus name de.yoxcu.stoandl. Sets the Wayland app_id / X11 WM_CLASS so the
    // compositor matches the window to de.yoxcu.stoandl.gui.desktop (data/) and its Icon=.
    QApplication::setDesktopFileName(QStringLiteral("de.yoxcu.stoandl.gui"));

    // Prefer the Breeze "by-the-book" look; honour an explicit override if set.
    if (qEnvironmentVariableIsEmpty("QT_QUICK_CONTROLS_STYLE"))
        QQuickStyle::setStyle(QStringLiteral("org.kde.desktop"));

    if (QIcon::themeName().isEmpty())
        QIcon::setThemeName(QStringLiteral("breeze"));

    // Window icon (X11 WM icon; on Wayland the icon comes from the .desktop match
    // above). Prefer the installed hicolor theme icon; fall back to the PNGs embedded
    // as a Qt resource so a run straight out of build/ still shows the icon.
    if (QIcon::hasThemeIcon(QStringLiteral("de.yoxcu.stoandl.gui"))) {
        QApplication::setWindowIcon(QIcon::fromTheme(QStringLiteral("de.yoxcu.stoandl.gui")));
    } else {
        QIcon fallback;
        for (int size : {16, 24, 32, 48, 64, 128, 256})
            fallback.addFile(QStringLiteral(":/icons/%1x%1/apps/de.yoxcu.stoandl.gui.png").arg(size));
        QApplication::setWindowIcon(fallback);
    }

    QQmlApplicationEngine engine;
    engine.loadFromModule("org.stoandl.gui", "Main");
    if (engine.rootObjects().isEmpty())
        return -1;

    return app.exec();
}
