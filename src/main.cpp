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
    QApplication::setDesktopFileName(QStringLiteral("org.kde.stoandl.gui"));

    // Prefer the Breeze "by-the-book" look; honour an explicit override if set.
    if (qEnvironmentVariableIsEmpty("QT_QUICK_CONTROLS_STYLE"))
        QQuickStyle::setStyle(QStringLiteral("org.kde.desktop"));

    if (QIcon::themeName().isEmpty())
        QIcon::setThemeName(QStringLiteral("breeze"));

    QQmlApplicationEngine engine;
    engine.loadFromModule("org.stoandl.gui", "Main");
    if (engine.rootObjects().isEmpty())
        return -1;

    return app.exec();
}
