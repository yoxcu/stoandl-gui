#include "SingleInstance.h"

#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusError>
#include <QDBusMessage>
#include <QDBusReply>
#include <QGuiApplication>
#include <QLoggingCategory>
#include <QQuickWindow>

namespace {
constexpr auto NAME  = "de.yoxcu.stoandl.gui";   // the app id, which a Flatpak may own by default
constexpr auto PATH  = "/de/yoxcu/stoandl/gui";
constexpr auto IFACE = "de.yoxcu.stoandl.Gui";
constexpr int ACTIVATE_TIMEOUT_MS = 3000;
}

Q_LOGGING_CATEGORY(lcInstance, "stoandl.instance", QtWarningMsg)

SingleInstance::SingleInstance(QObject *parent)
    : QObject(parent)
{
}

bool SingleInstance::claimOrActivate(const QString &activationToken)
{
    QDBusConnection bus = QDBusConnection::sessionBus();
    if (!bus.isConnected() || !bus.interface())
        return true;   // nothing to coordinate on: just run

    // Export first, so the name never points at a missing object.
    bus.registerObject(QString::fromLatin1(PATH), this, QDBusConnection::ExportAllSlots);

    // Two tries: the owner can quit between our claim and the Activate call, and then the name is free.
    for (int attempt = 0; attempt < 2; ++attempt) {
        const QDBusReply<QDBusConnectionInterface::RegisterServiceReply> reply =
            bus.interface()->registerService(QString::fromLatin1(NAME),
                                             QDBusConnectionInterface::DontQueueService,
                                             QDBusConnectionInterface::DontAllowReplacement);
        if (!reply.isValid()) {
            qCWarning(lcInstance).noquote() << "could not claim" << NAME << "—" << reply.error().message();
            return true;   // can't tell whether another instance runs: better two windows than none
        }
        if (reply.value() == QDBusConnectionInterface::ServiceRegistered)
            return true;

        QDBusMessage m = QDBusMessage::createMethodCall(QString::fromLatin1(NAME), QString::fromLatin1(PATH),
                                                        QString::fromLatin1(IFACE), QStringLiteral("Activate"));
        m << activationToken;
        const QDBusMessage r = bus.call(m, QDBus::Block, ACTIVATE_TIMEOUT_MS);
        if (r.type() != QDBusMessage::ErrorMessage) {
            qCInfo(lcInstance) << "stoandl-gui is already running; activated it";
            bus.unregisterObject(QString::fromLatin1(PATH));
            return false;
        }
        if (r.errorName() != QLatin1String("org.freedesktop.DBus.Error.ServiceUnknown")
            && r.errorName() != QLatin1String("org.freedesktop.DBus.Error.NameHasNoOwner")) {
            // Running but not answering (still starting, or busy): its window comes up on its own.
            qCWarning(lcInstance).noquote() << "stoandl-gui is already running but did not answer Activate:"
                                            << r.errorMessage();
            bus.unregisterObject(QString::fromLatin1(PATH));
            return false;
        }
    }
    return true;
}

void SingleInstance::Activate(const QString &activationToken)
{
    qCInfo(lcInstance) << "another launch asked to activate the window";
    QQuickWindow *window = nullptr;
    const auto windows = QGuiApplication::topLevelWindows();
    for (QWindow *w : windows) {
        if (auto *qw = qobject_cast<QQuickWindow *>(w); qw && qw->type() == Qt::Window) {
            window = qw;
            break;
        }
    }
    if (!window)
        return;   // still loading: the window shows itself when it is ready
    if (!activationToken.isEmpty())
        qputenv("XDG_ACTIVATION_TOKEN", activationToken.toUtf8());
    window->setWindowStates(window->windowStates() & ~Qt::WindowMinimized);
    window->show();
    window->raise();
    window->requestActivate();
}
