#pragma once

#include <QObject>
#include <QString>

// One stoandl-gui per session (no KF6 DBusAddons: plain QtDBus). The first instance owns the
// session-bus name de.yoxcu.stoandl.gui and exports Activate() at /de/yoxcu/stoandl/gui; a later
// launch (a re-tap on the launcher while the first one is still starting) finds the name taken,
// asks the owner to bring its window forward, and exits instead of opening a second window.
class SingleInstance : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "de.yoxcu.stoandl.Gui")

public:
    explicit SingleInstance(QObject *parent = nullptr);

    // true: this process is the instance (or there is no session bus to coordinate on) and should
    // run. false: another instance owns the name and has been asked to activate; exit 0.
    // `activationToken` is this launch's XDG_ACTIVATION_TOKEN (Wayland), handed to the owner.
    bool claimOrActivate(const QString &activationToken);

public Q_SLOTS:
    // Raise and activate the main window. `activationToken` is the launching instance's
    // XDG_ACTIVATION_TOKEN ("" when it had none): Qt's Wayland plugin reads that variable in
    // requestActivate(), which lets the compositor grant focus to a window that didn't have it.
    void Activate(const QString &activationToken);
};
