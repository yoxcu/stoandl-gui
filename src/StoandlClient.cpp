#include "StoandlClient.h"

#include <QTimer>
#include <QProcess>
#include <QUrl>
#include <QDesktopServices>
#include <QStandardPaths>
#include <QDateTime>
#include <QDir>
#include <QDBusMessage>
#include <QDBusPendingCall>
#include <QDBusPendingReply>
#include <QDBusPendingCallWatcher>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QJsonValue>
#include <QLoggingCategory>

#include <algorithm>

namespace {
// Service contract — docs/handoff/dbus-interface.md §"Service summary".
constexpr auto SERVICE = "de.yoxcu.stoandl";
constexpr auto PATH    = "/de/yoxcu/stoandl";
constexpr auto IFACE   = "de.yoxcu.stoandl.Control";

// org.freedesktop.DBus (the bus daemon itself) — for NameHasOwner / NameOwnerChanged.
constexpr auto DBUS_SERVICE = "org.freedesktop.DBus";
constexpr auto DBUS_PATH    = "/org/freedesktop/DBus";
constexpr auto DBUS_IFACE   = "org.freedesktop.DBus";

constexpr int CALL_TIMEOUT_MS = 10000;  // ordinary request/response
constexpr int FIND_TIMEOUT_MS = 20000;  // FindWatch may linger daemon-side
constexpr int NAME_TIMEOUT_MS = 3000;

// Pair/Repair poll: 1.5 s cadence, 145 s ceiling (dbus-interface.md §Long-running operations).
constexpr int PAIR_INTERVAL_MS = 1500;
constexpr int PAIR_TIMEOUT_MS  = 145000;

// Focus poll of ListWatches: 4 s while a watch screen is foreground.
constexpr int WATCH_INTERVAL_MS = 4000;

// Firmware flash poll: 0.8 s cadence, 600 s ceiling.
constexpr int FW_INTERVAL_MS = 800;
constexpr int FW_TIMEOUT_MS  = 600000;

// Language install poll: 0.6 s cadence, 180 s ceiling.
constexpr int LANG_INTERVAL_MS = 600;
constexpr int LANG_TIMEOUT_MS  = 180000;
} // namespace

// Failures are logged to the terminal (stderr) as well as shown as in-app toasts —
// run the GUI from a shell to see them. Warnings are on by default; silence with
//   QT_LOGGING_RULES="stoandl.warning=false"   or get the full call trace with
//   QT_LOGGING_RULES="stoandl.debug=true"
Q_LOGGING_CATEGORY(lcStoandl, "stoandl", QtWarningMsg)

StoandlClient::StoandlClient(QObject *parent)
    : QObject(parent)
    , m_bus(QDBusConnection::sessionBus())
{
    m_watchTimer = new QTimer(this);
    m_watchTimer->setInterval(WATCH_INTERVAL_MS);
    connect(m_watchTimer, &QTimer::timeout, this, &StoandlClient::refreshWatches);

    m_pairTimer = new QTimer(this);
    m_pairTimer->setInterval(PAIR_INTERVAL_MS);
    connect(m_pairTimer, &QTimer::timeout, this, &StoandlClient::pollPairOnce);

    m_fwTimer = new QTimer(this);
    m_fwTimer->setInterval(FW_INTERVAL_MS);
    connect(m_fwTimer, &QTimer::timeout, this, &StoandlClient::firmwarePollOnce);

    m_langTimer = new QTimer(this);
    m_langTimer->setInterval(LANG_INTERVAL_MS);
    connect(m_langTimer, &QTimer::timeout, this, &StoandlClient::languagePollOnce);

    // React to the daemon coming up / going down without polling NameHasOwner.
    m_bus.connect(DBUS_SERVICE, DBUS_PATH, DBUS_IFACE, QStringLiteral("NameOwnerChanged"),
                  this, SLOT(onNameOwnerChanged(QString, QString, QString)));

    recheckDaemon();
}

// --- parsing ---------------------------------------------------------------

StoandlClient::Status StoandlClient::parseStatus(const QString &s)
{
    // Split on the FIRST ':' only — the tail can itself contain colons.
    const int i = s.indexOf(QLatin1Char(':'));
    Status st;
    if (i < 0) {
        st.kind = s;
    } else {
        st.kind = s.left(i);
        st.tail = s.mid(i + 1);
    }
    if (!st.tail.isEmpty())
        st.fields = st.tail.split(QLatin1Char('\t'));
    return st;
}

QVariantMap StoandlClient::statusMap(const Status &s)
{
    QVariantMap m;
    m[QStringLiteral("kind")]     = s.kind;
    m[QStringLiteral("tail")]     = s.tail;
    m[QStringLiteral("fields")]   = s.fields;
    m[QStringLiteral("ok")]       = s.ok();
    m[QStringLiteral("notready")] = (s.kind == QStringLiteral("notready"));
    return m;
}

// --- low-level D-Bus -------------------------------------------------------

QDBusMessage StoandlClient::methodCall(const QString &method, const QVariantList &args) const
{
    QDBusMessage m = QDBusMessage::createMethodCall(SERVICE, PATH, IFACE, method);
    if (!args.isEmpty())
        m.setArguments(args);
    return m;
}

StoandlClient::Status StoandlClient::callStatus(const QString &method, const QVariantList &args)
{
    // Build the message by hand (no QDBusInterface) so a missing daemon can't
    // block us on introspection — an unowned name just yields an error reply.
    const QDBusMessage reply = m_bus.call(methodCall(method, args), QDBus::Block, CALL_TIMEOUT_MS);
    if (reply.type() == QDBusMessage::ErrorMessage) {
        qCWarning(lcStoandl).noquote().nospace()
            << "D-Bus " << method << " failed: " << reply.errorName()
            << " — " << reply.errorMessage();
        return { QStringLiteral("error"), reply.errorMessage(), {} };
    }
    const Status st = parseStatus(reply.arguments().value(0).toString());
    // Daemon-reported failures (a valid reply whose status kind is an error) also
    // go to the terminal so the popup isn't the only trace.
    if (st.kind == QStringLiteral("error") || st.kind == QStringLiteral("failed")
        || st.kind == QStringLiteral("timeout"))
        qCWarning(lcStoandl).noquote().nospace() << method << " -> " << st.kind << ": " << st.tail;
    else
        qCDebug(lcStoandl).noquote().nospace() << method << " -> " << st.kind;
    return st;
}

// --- generic ---------------------------------------------------------------

QVariantMap StoandlClient::call(const QString &method, const QVariantList &args)
{
    return statusMap(callStatus(method, args));
}

QVariantList StoandlClient::list(const QString &method, const QVariantList &args)
{
    QVariantList out;
    const QDBusMessage reply = m_bus.call(methodCall(method, args), QDBus::Block, CALL_TIMEOUT_MS);
    if (reply.type() == QDBusMessage::ErrorMessage) {
        qCWarning(lcStoandl).noquote().nospace()
            << "D-Bus " << method << " failed: " << reply.errorName()
            << " — " << reply.errorMessage();
        return out;
    }
    const QStringList rows = reply.arguments().value(0).toStringList();
    for (const QString &row : rows)
        out.append(QVariant(row.split(QLatin1Char('\t'))));
    return out;
}

// --- typed wrappers: Watch -------------------------------------------------

QVariantList StoandlClient::listWatches()
{
    QVariantList rows;
    const QVariantList records = list(QStringLiteral("ListWatches"));
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        QVariantMap m;
        m[QStringLiteral("name")]      = f.value(0);
        m[QStringLiteral("state")]     = f.value(1);
        m[QStringLiteral("battery")]   = f.value(2);
        m[QStringLiteral("transport")] = f.value(3);   // HOOK #4: ble|classic, empty when disconnected
        m[QStringLiteral("connected")] = (f.value(1) == QStringLiteral("connected"));
        rows.append(m);
    }
    return rows;
}

QVariantMap StoandlClient::battery()                       { return statusMap(callStatus(QStringLiteral("Battery"))); }
QVariantMap StoandlClient::connectWatch(const QString &n)  { return statusMap(callStatus(QStringLiteral("Connect"), {n})); }
QVariantMap StoandlClient::pair()                          { return statusMap(callStatus(QStringLiteral("Pair"))); }
QVariantMap StoandlClient::pairStatusNow()                 { return statusMap(callStatus(QStringLiteral("PairStatus"))); }
QVariantMap StoandlClient::confirmPairing(bool accept)     { return statusMap(callStatus(QStringLiteral("ConfirmPairing"), { accept })); }
QVariantMap StoandlClient::repair(const QString &n)        { return statusMap(callStatus(QStringLiteral("Repair"), {n})); }
QVariantMap StoandlClient::unpair(const QString &n)        { return statusMap(callStatus(QStringLiteral("Unpair"), {n})); }

QVariantMap StoandlClient::watchInfoText()
{
    const Status s = callStatus(QStringLiteral("WatchInfoText"));
    QVariantMap m;
    m[QStringLiteral("kind")] = s.kind;
    m[QStringLiteral("text")] = s.tail;
    return m;
}

// --- typed wrappers: Apps & Faces ------------------------------------------

QVariantList StoandlClient::listApps()
{
    // Record: uuid \t type \t order \t flags \t title \t developer
    // flags is a comma-joined subset of {active, sideloaded, config, system}.
    QVariantList rows;
    const QVariantList records = list(QStringLiteral("ListApps"));
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        const QString type  = f.value(1);
        const QStringList flags =
            f.value(3).isEmpty() ? QStringList() : f.value(3).split(QLatin1Char(','));

        QVariantMap m;
        m[QStringLiteral("uuid")]       = f.value(0);
        m[QStringLiteral("type")]       = type;
        m[QStringLiteral("order")]      = f.value(2).toInt();
        m[QStringLiteral("title")]      = f.value(4);
        m[QStringLiteral("developer")]  = f.value(5);
        m[QStringLiteral("flags")]      = flags;
        m[QStringLiteral("active")]     = flags.contains(QStringLiteral("active"));
        m[QStringLiteral("system")]     = flags.contains(QStringLiteral("system"));
        m[QStringLiteral("config")]     = flags.contains(QStringLiteral("config"));
        m[QStringLiteral("sideloaded")] = flags.contains(QStringLiteral("sideloaded"));
        m[QStringLiteral("synced")]     = flags.contains(QStringLiteral("synced")); // HOOK #4
        m[QStringLiteral("isFace")]     = (type == QStringLiteral("watchface"));
        rows.append(m);
    }
    // Stable order by the locker `order` field so the list doesn't jump around.
    std::stable_sort(rows.begin(), rows.end(), [](const QVariant &a, const QVariant &b) {
        return a.toMap().value(QStringLiteral("order")).toInt()
             < b.toMap().value(QStringLiteral("order")).toInt();
    });
    return rows;
}

QVariantMap StoandlClient::launchApp(const QString &id) { return statusMap(callStatus(QStringLiteral("LaunchApp"), {id})); }
QVariantMap StoandlClient::removeApp(const QString &id) { return statusMap(callStatus(QStringLiteral("RemoveApp"), {id})); }

QVariantMap StoandlClient::sideloadApp(const QUrl &fileUrl)
{
    // Paths are absolute and daemon-side; the GUI is co-located, so the local
    // path of the chosen file is the daemon-side path.
    const QString path = fileUrl.toLocalFile();
    if (path.isEmpty())
        return statusMap({ QStringLiteral("error"), QStringLiteral("not a local file"), {} });
    return statusMap(callStatus(QStringLiteral("SideloadApp"), {path}));
}

QVariantMap StoandlClient::openConfig(const QString &id)
{
    // OpenConfig returns a config URL for a *running* app, or "" if none.
    // Its exact framing isn't verifiable against a live daemon here, so accept
    // both a bare URL and the "kind:tail" status convention. v1 opens the URL in
    // the system browser via xdg-open (QDesktopServices) and skips WebviewClose.
    const QDBusMessage reply =
        m_bus.call(methodCall(QStringLiteral("OpenConfig"), {id}), QDBus::Block, CALL_TIMEOUT_MS);

    QVariantMap m;
    if (reply.type() == QDBusMessage::ErrorMessage) {
        qCWarning(lcStoandl).noquote().nospace()
            << "D-Bus OpenConfig failed: " << reply.errorName() << " — " << reply.errorMessage();
        m[QStringLiteral("kind")] = QStringLiteral("error");
        m[QStringLiteral("msg")]  = reply.errorMessage();
        m[QStringLiteral("url")]  = QString();
        m[QStringLiteral("opened")] = false;
        return m;
    }

    const QString raw = reply.arguments().value(0).toString();
    QString url;
    QString kind = QStringLiteral("ok");
    QString msg;

    if (raw.isEmpty()) {
        kind = QStringLiteral("none");
    } else if (raw.startsWith(QStringLiteral("http://")) || raw.startsWith(QStringLiteral("https://"))
               || raw.startsWith(QStringLiteral("file://"))) {
        url = raw; // bare URL
    } else {
        const Status s = parseStatus(raw);
        if (s.kind == QStringLiteral("ok")) {
            url = s.tail;
        } else {
            kind = s.kind;   // error / notready / notfound / disabled / ...
            msg = s.tail;
        }
    }

    bool opened = false;
    if (!url.isEmpty())
        opened = QDesktopServices::openUrl(QUrl(url));

    m[QStringLiteral("kind")]   = kind;
    m[QStringLiteral("url")]    = url;
    m[QStringLiteral("msg")]    = msg;
    m[QStringLiteral("opened")] = opened;
    return m;
}

void StoandlClient::refreshApps()
{
    recheckDaemon();
    Q_EMIT appsChanged(m_daemonUp ? listApps() : QVariantList());
}

// --- typed wrappers: Plugins (extensions) ----------------------------------

QVariantList StoandlClient::extList()
{
    // Record (HOOK #7): name \t installed|missing \t enabled|disabled \t
    //                   running|stopped \t config(none|url|schema) \t description
    QVariantList rows;
    const QVariantList records = list(QStringLiteral("ExtList"));
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        const QString cfg = f.value(4);
        QVariantMap m;
        m[QStringLiteral("name")]        = f.value(0);
        m[QStringLiteral("installed")]   = (f.value(1) == QStringLiteral("installed"));
        m[QStringLiteral("enabled")]     = (f.value(2) == QStringLiteral("enabled"));
        m[QStringLiteral("running")]     = (f.value(3) == QStringLiteral("running"));
        m[QStringLiteral("config")]      = cfg.isEmpty() ? QStringLiteral("none") : cfg;
        m[QStringLiteral("hasConfig")]   = (cfg == QStringLiteral("url") || cfg == QStringLiteral("schema"));
        m[QStringLiteral("description")] = f.value(5);
        rows.append(m);
    }
    return rows;
}

QVariantMap StoandlClient::extEnable(const QString &name)  { return statusMap(callStatus(QStringLiteral("ExtEnable"), {name})); }
QVariantMap StoandlClient::extDisable(const QString &name) { return statusMap(callStatus(QStringLiteral("ExtDisable"), {name})); }
QVariantMap StoandlClient::extRestart(const QString &name) { return statusMap(callStatus(QStringLiteral("ExtRestart"), {name})); }

QVariantMap StoandlClient::extUninstall(const QString &name, bool keepConfig)
{
    return statusMap(callStatus(QStringLiteral("ExtUninstall"), {name, keepConfig}));
}

QVariantMap StoandlClient::extInstall(const QUrl &archiveUrl)
{
    const QString path = archiveUrl.toLocalFile();
    if (path.isEmpty())
        return statusMap({ QStringLiteral("error"), QStringLiteral("not a local file"), {} });
    return statusMap(callStatus(QStringLiteral("ExtInstall"), {path}));
}

void StoandlClient::refreshExtensions()
{
    recheckDaemon();
    Q_EMIT extensionsChanged(m_daemonUp ? extList() : QVariantList());
}

// --- typed wrappers: Sync --------------------------------------------------

QVariantMap StoandlClient::syncWeather()  { return statusMap(callStatus(QStringLiteral("SyncWeather"))); }
QVariantMap StoandlClient::syncCalendar() { return statusMap(callStatus(QStringLiteral("SyncCalendar"))); }
QVariantMap StoandlClient::syncHealth()   { return statusMap(callStatus(QStringLiteral("SyncHealth"))); }

QVariantList StoandlClient::listCalendars()
{
    // Record: id \t name \t enabled|disabled
    QVariantList rows;
    const QVariantList records = list(QStringLiteral("ListCalendars"));
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        QVariantMap m;
        m[QStringLiteral("id")]      = f.value(0);
        m[QStringLiteral("name")]    = f.value(1);
        m[QStringLiteral("enabled")] = (f.value(2) == QStringLiteral("enabled"));
        rows.append(m);
    }
    return rows;
}

QVariantMap StoandlClient::setCalendarEnabled(const QString &id, bool enabled)
{
    return statusMap(callStatus(QStringLiteral("SetCalendarEnabled"), {id, enabled}));
}

void StoandlClient::refreshCalendars()
{
    recheckDaemon();
    Q_EMIT calendarsChanged(m_daemonUp ? listCalendars() : QVariantList());
}

// --- typed wrappers: System / firmware -------------------------------------

int StoandlClient::parsePercent(const QString &s)
{
    QString num;
    bool started = false;
    for (const QChar c : s) {
        if (c.isDigit()) { num.append(c); started = true; }
        else if (started) break;
    }
    return num.isEmpty() ? -1 : num.toInt();
}

QVariantMap StoandlClient::checkFirmware()
{
    const Status s = callStatus(QStringLiteral("CheckFirmware"));
    QVariantMap m = statusMap(s);
    if (s.kind == QStringLiteral("ok")) {
        // ok:<board>\t<current>\t<latest>\t<asset>\t<yes|no>\t<source>\t<changelogUrl>
        // (changelogUrl is a HOOK addition so the Watch banner's "What's new" works.)
        m[QStringLiteral("board")]           = s.fields.value(0);
        m[QStringLiteral("current")]         = s.fields.value(1);
        m[QStringLiteral("latest")]          = s.fields.value(2);
        m[QStringLiteral("asset")]           = s.fields.value(3);
        m[QStringLiteral("updateAvailable")] = (s.fields.value(4) == QStringLiteral("yes"));
        m[QStringLiteral("source")]          = s.fields.value(5);
        m[QStringLiteral("changelogUrl")]    = s.fields.value(6);
    }
    return m;
}

QVariantMap StoandlClient::updateFirmware()
{
    const Status s = callStatus(QStringLiteral("UpdateFirmware"));
    if (s.kind == QStringLiteral("ok"))
        startFirmwarePoll();
    return statusMap(s);
}

QVariantMap StoandlClient::sideloadFirmware(const QUrl &fileUrl)
{
    const QString path = fileUrl.toLocalFile();
    if (path.isEmpty())
        return statusMap({ QStringLiteral("error"), QStringLiteral("not a local file"), {} });
    const Status s = callStatus(QStringLiteral("SideloadFirmware"), {path});
    if (s.kind == QStringLiteral("ok"))
        startFirmwarePoll();
    return statusMap(s);
}

void StoandlClient::startFirmwarePoll()
{
    m_fwElapsedMs = 0;
    m_fwSeenActivity = false;
    if (!m_fwTimer->isActive())
        m_fwTimer->start();
}

void StoandlClient::stopFirmwarePoll() { m_fwTimer->stop(); }

void StoandlClient::firmwarePollOnce()
{
    m_fwElapsedMs += FW_INTERVAL_MS;
    if (m_fwElapsedMs > FW_TIMEOUT_MS) {
        stopFirmwarePoll();
        Q_EMIT firmwareStatus(QStringLiteral("timeout"), -1, QStringLiteral("Flash timed out"));
        return;
    }
    const Status s = callStatus(QStringLiteral("FirmwareStatus"));
    const QString k = s.kind;
    if (k == QStringLiteral("downloading") || k == QStringLiteral("waiting") || k == QStringLiteral("inprogress"))
        m_fwSeenActivity = true;

    // Success = a `reboot:` OR a `notready:` seen *after* activity (link drops on reboot).
    if (k == QStringLiteral("reboot") || (k == QStringLiteral("notready") && m_fwSeenActivity)) {
        stopFirmwarePoll();
        Q_EMIT firmwareStatus(QStringLiteral("success"), 100, QStringLiteral("Watch is rebooting"));
        return;
    }
    if (k == QStringLiteral("failed")) {
        stopFirmwarePoll();
        Q_EMIT firmwareStatus(QStringLiteral("failed"), -1, s.tail);
        return;
    }
    const int pct = (k == QStringLiteral("inprogress")) ? parsePercent(s.tail) : -1;
    Q_EMIT firmwareStatus(k, pct, s.tail); // idle / downloading / waiting / inprogress / (pre-activity notready)
}

// --- typed wrappers: System / language packs -------------------------------

QVariantList StoandlClient::listLanguages()
{
    // Record: id \t isoLocal \t displayName \t installed(yes|no) \t source(rebble|github)
    QVariantList rows;
    const QVariantList records = list(QStringLiteral("ListLanguages"));
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        QVariantMap m;
        m[QStringLiteral("id")]          = f.value(0);
        m[QStringLiteral("isoLocal")]    = f.value(1);
        m[QStringLiteral("displayName")] = f.value(2);
        m[QStringLiteral("installed")]   = (f.value(3) == QStringLiteral("yes"));
        m[QStringLiteral("source")]      = f.value(4);
        rows.append(m);
    }
    return rows;
}

QVariantMap StoandlClient::installLanguage(const QString &query)
{
    const Status s = callStatus(QStringLiteral("InstallLanguage"), {query});
    if (s.kind == QStringLiteral("ok"))
        startLanguagePoll();
    return statusMap(s);
}

QVariantMap StoandlClient::sideloadLanguage(const QUrl &fileUrl)
{
    const QString path = fileUrl.toLocalFile();
    if (path.isEmpty())
        return statusMap({ QStringLiteral("error"), QStringLiteral("not a local file"), {} });
    const Status s = callStatus(QStringLiteral("SideloadLanguage"), {path});
    if (s.kind == QStringLiteral("ok"))
        startLanguagePoll();
    return statusMap(s);
}

void StoandlClient::startLanguagePoll()
{
    m_langElapsedMs = 0;
    m_langSeenActivity = false;
    m_langFirstPoll = true;
    if (!m_langTimer->isActive())
        m_langTimer->start();
}

void StoandlClient::stopLanguagePoll() { m_langTimer->stop(); }

void StoandlClient::languagePollOnce()
{
    m_langElapsedMs += LANG_INTERVAL_MS;
    if (m_langElapsedMs > LANG_TIMEOUT_MS) {
        stopLanguagePoll();
        Q_EMIT languageStatus(QStringLiteral("timeout"), -1, QStringLiteral("Install timed out"));
        return;
    }
    const Status s = callStatus(QStringLiteral("LanguageStatus"));
    const QString k = s.kind;

    // Skip one stale sticky terminal on the first poll (previous install's value).
    if (m_langFirstPoll) {
        m_langFirstPoll = false;
        if (k == QStringLiteral("done") || k == QStringLiteral("idle") || k == QStringLiteral("failed"))
            return;
    }
    if (k == QStringLiteral("downloading") || k == QStringLiteral("installing"))
        m_langSeenActivity = true;

    if (k == QStringLiteral("done")) {
        stopLanguagePoll();
        Q_EMIT languageStatus(QStringLiteral("success"), 100, s.tail);
        return;
    }
    if (k == QStringLiteral("failed")) {
        stopLanguagePoll();
        Q_EMIT languageStatus(QStringLiteral("failed"), -1, s.tail);
        return;
    }
    if (k == QStringLiteral("notready") && m_langSeenActivity) {
        stopLanguagePoll();
        Q_EMIT languageStatus(QStringLiteral("disconnected"), -1, QStringLiteral("Watch disconnected"));
        return;
    }
    const int pct = (k == QStringLiteral("installing")) ? parsePercent(s.tail) : -1;
    Q_EMIT languageStatus(k, pct, s.tail);
}

// --- typed wrappers: System / diagnostics ----------------------------------

QVariantMap StoandlClient::takeScreenshot()
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::TempLocation);
    const QString path = QDir(dir).filePath(
        QStringLiteral("stoandl-screenshot-%1.png").arg(QDateTime::currentMSecsSinceEpoch()));
    const Status s = callStatus(QStringLiteral("TakeScreenshot"), {path});
    QVariantMap m;
    m[QStringLiteral("kind")] = s.kind;
    if (s.kind == QStringLiteral("ok")) {
        m[QStringLiteral("path")]   = s.fields.value(0);
        m[QStringLiteral("width")]  = s.fields.value(1).toInt();
        m[QStringLiteral("height")] = s.fields.value(2).toInt();
    } else {
        m[QStringLiteral("msg")] = s.tail;
    }
    return m;
}

QVariantMap StoandlClient::gatherLogs()
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::TempLocation);
    const QString path = QDir(dir).filePath(
        QStringLiteral("stoandl-logs-%1.txt").arg(QDateTime::currentMSecsSinceEpoch()));
    const Status s = callStatus(QStringLiteral("GatherLogs"), {path});
    QVariantMap m;
    m[QStringLiteral("kind")] = s.kind;
    if (s.kind == QStringLiteral("ok"))
        m[QStringLiteral("path")] = s.fields.value(0);
    else
        m[QStringLiteral("msg")] = s.tail;
    return m;
}

// --- typed wrappers: System / reset ----------------------------------------

QVariantMap StoandlClient::resetIntoRecovery() { return statusMap(callStatus(QStringLiteral("ResetIntoRecovery"))); }
QVariantMap StoandlClient::factoryReset()      { return statusMap(callStatus(QStringLiteral("FactoryReset"))); }

// --- CLI shell-outs (backup / restore / support) ---------------------------

void StoandlClient::runCli(const QString &op, const QStringList &args)
{
    // backup/restore/support are CLI-local (`tar` over ~/.config/stoandl) and not
    // on D-Bus; run the co-located `stoandl` binary asynchronously.
    auto *p = new QProcess(this);
    connect(p, &QProcess::errorOccurred, this, [this, op, p](QProcess::ProcessError e) {
        if (e == QProcess::FailedToStart) {
            qCWarning(lcStoandl).noquote() << "CLI" << op << "failed: stoandl not found on PATH";
            Q_EMIT cliResult(op, false, QStringLiteral("stoandl CLI not found on PATH"));
            p->deleteLater();
        }
    });
    connect(p, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
            [this, op, p](int code, QProcess::ExitStatus st) {
        QString out = QString::fromUtf8(p->readAllStandardError()).trimmed();
        if (out.isEmpty())
            out = QString::fromUtf8(p->readAllStandardOutput()).trimmed();
        const bool ok = (st == QProcess::NormalExit && code == 0);
        if (!ok)
            qCWarning(lcStoandl).noquote().nospace()
                << "CLI " << op << " failed (exit " << code << "): " << out;
        Q_EMIT cliResult(op, ok, out);
        p->deleteLater();
    });
    p->start(QStringLiteral("stoandl"), args);
}

void StoandlClient::backup(const QUrl &outFile)
{
    QStringList args{ QStringLiteral("backup") };
    const QString path = outFile.toLocalFile();
    if (!path.isEmpty())
        args << path;
    runCli(QStringLiteral("backup"), args);
}

void StoandlClient::restore(const QUrl &inFile)
{
    const QString path = inFile.toLocalFile();
    if (path.isEmpty()) {
        Q_EMIT cliResult(QStringLiteral("restore"), false, QStringLiteral("no file selected"));
        return;
    }
    runCli(QStringLiteral("restore"), { QStringLiteral("restore"), path });
}

void StoandlClient::supportBundle(const QUrl &outFile)
{
    QStringList args{ QStringLiteral("support") };
    const QString path = outFile.toLocalFile();
    if (!path.isEmpty())
        args << path;
    runCli(QStringLiteral("support"), args);
}

void StoandlClient::findWatch()
{
    // Asynchronous: FindWatch rings until a button is pressed, so a blocking call
    // would freeze the UI thread. Fire-and-forget; report the b return via a signal.
    const QDBusPendingCall pc = m_bus.asyncCall(methodCall(QStringLiteral("FindWatch"), {}), FIND_TIMEOUT_MS);
    auto *w = new QDBusPendingCallWatcher(pc, this);
    connect(w, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *self) {
        const QDBusPendingReply<bool> r = *self;
        if (r.isError())
            qCWarning(lcStoandl).noquote().nospace()
                << "D-Bus FindWatch failed: " << r.error().name() << " — " << r.error().message();
        Q_EMIT findWatchResult(!r.isError() && r.value());
        self->deleteLater();
    });
}

// --- Watch details / rename / dev connection / coredump --------------------

QVariantMap StoandlClient::watchDetails()
{
    // WatchDetails() -> ok:name\tcode\tmodel\tplatform\ttransport\tfirmware\tserial\tbattery\tlastSync
    const Status s = callStatus(QStringLiteral("WatchDetails"));
    QVariantMap m;
    m[QStringLiteral("kind")] = s.kind;
    if (s.kind == QStringLiteral("ok")) {
        m[QStringLiteral("name")]      = s.fields.value(0);
        m[QStringLiteral("code")]      = s.fields.value(1);
        m[QStringLiteral("model")]     = s.fields.value(2);
        m[QStringLiteral("platform")]  = s.fields.value(3);
        m[QStringLiteral("transport")] = s.fields.value(4);
        m[QStringLiteral("firmware")]  = s.fields.value(5);
        m[QStringLiteral("serial")]    = s.fields.value(6);
        m[QStringLiteral("battery")]   = s.fields.value(7);
        m[QStringLiteral("lastSync")]  = s.fields.value(8);
    } else {
        m[QStringLiteral("msg")] = s.tail;
    }
    return m;
}

QVariantMap StoandlClient::setWatchNickname(const QString &name, const QString &nickname)
{
    return statusMap(callStatus(QStringLiteral("SetWatchNickname"), {name, nickname}));
}

QVariantMap StoandlClient::startDevConnection()
{
    const Status s = callStatus(QStringLiteral("StartDevConnection"));
    QVariantMap m = statusMap(s);
    if (s.kind == QStringLiteral("ok"))
        m[QStringLiteral("port")] = s.tail;   // e.g. "9000"
    return m;
}

QVariantMap StoandlClient::stopDevConnection() { return statusMap(callStatus(QStringLiteral("StopDevConnection"))); }

QVariantMap StoandlClient::devConnectionStatus()
{
    const Status s = callStatus(QStringLiteral("DevConnectionStatus"));
    QVariantMap m = statusMap(s);
    // ok:active / ok:inactive / notready:
    m[QStringLiteral("active")] = (s.kind == QStringLiteral("ok") && s.tail == QStringLiteral("active"));
    return m;
}

QVariantMap StoandlClient::getCoreDump()
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::TempLocation);
    const QString path = QDir(dir).filePath(
        QStringLiteral("stoandl-coredump-%1.bin").arg(QDateTime::currentMSecsSinceEpoch()));
    const Status s = callStatus(QStringLiteral("GetCoreDump"), {path});
    QVariantMap m;
    m[QStringLiteral("kind")] = s.kind;          // ok / none / notready / error
    if (s.kind == QStringLiteral("ok"))
        m[QStringLiteral("path")] = s.fields.value(0);
    else
        m[QStringLiteral("msg")] = s.tail;
    return m;
}

// --- Extensions: config (HOOK #7) ------------------------------------------

QVariantMap StoandlClient::extOpenConfig(const QString &name)
{
    // ExtOpenConfig(s) -> ok:<url> (open it) / none: / error: / notfound:
    const Status s = callStatus(QStringLiteral("ExtOpenConfig"), {name});
    QVariantMap m;
    m[QStringLiteral("kind")]   = s.kind;
    m[QStringLiteral("url")]    = QString();
    m[QStringLiteral("opened")] = false;
    if (s.kind == QStringLiteral("ok")) {
        m[QStringLiteral("url")]    = s.tail;
        m[QStringLiteral("opened")] = QDesktopServices::openUrl(QUrl(s.tail));
    } else {
        m[QStringLiteral("msg")] = s.tail;
    }
    return m;
}

QVariantList StoandlClient::extConfigSchema(const QString &name)
{
    // ExtConfigSchema(s) -> ok:<json-array> ; one object per field.
    QVariantList out;
    const Status s = callStatus(QStringLiteral("ExtConfigSchema"), {name});
    if (s.kind != QStringLiteral("ok"))
        return out;
    const QJsonDocument doc = QJsonDocument::fromJson(s.tail.toUtf8());
    if (!doc.isArray())
        return out;
    const QJsonArray arr = doc.array();
    for (const QJsonValue &v : arr) {
        const QJsonObject o = v.toObject();
        QVariantMap f;
        f[QStringLiteral("key")]    = o.value(QStringLiteral("key")).toString();
        f[QStringLiteral("type")]   = o.value(QStringLiteral("type")).toString();
        f[QStringLiteral("label")]  = o.value(QStringLiteral("label")).toString();
        f[QStringLiteral("secret")] = o.value(QStringLiteral("secret")).toBool();
        QStringList opts;
        for (const QJsonValue &ov : o.value(QStringLiteral("options")).toArray())
            opts << ov.toString();
        f[QStringLiteral("options")] = opts;
        out.append(f);
    }
    return out;
}

QVariantMap StoandlClient::extGetConfig(const QString &name)
{
    // ExtGetConfig(s) -> ok:<json-object>
    const Status s = callStatus(QStringLiteral("ExtGetConfig"), {name});
    QVariantMap m;
    m[QStringLiteral("kind")] = s.kind;
    if (s.kind == QStringLiteral("ok")) {
        const QJsonDocument doc = QJsonDocument::fromJson(s.tail.toUtf8());
        if (doc.isObject())
            m[QStringLiteral("values")] = doc.object().toVariantMap();
    } else {
        m[QStringLiteral("msg")] = s.tail;
    }
    return m;
}

QVariantMap StoandlClient::extSetConfig(const QString &name, const QVariantMap &values)
{
    const QJsonDocument doc(QJsonObject::fromVariantMap(values));
    const QString json = QString::fromUtf8(doc.toJson(QJsonDocument::Compact));
    return statusMap(callStatus(QStringLiteral("ExtSetConfig"), {name, json}));
}

// --- Sync services: status + master toggle (HOOK #5) -----------------------

QVariantList StoandlClient::getSyncStatus()
{
    // Record: service \t enabled \t available \t lastSync
    QVariantList rows;
    const QVariantList records = list(QStringLiteral("GetSyncStatus"));
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        QVariantMap m;
        m[QStringLiteral("service")]   = f.value(0);
        m[QStringLiteral("enabled")]   = (f.value(1) == QStringLiteral("enabled"));
        m[QStringLiteral("available")] = (f.value(2) == QStringLiteral("available"));
        m[QStringLiteral("lastSync")]  = f.value(3);
        rows.append(m);
    }
    return rows;
}

QVariantMap StoandlClient::setSyncEnabled(const QString &service, bool enabled)
{
    return statusMap(callStatus(QStringLiteral("SetSyncEnabled"), {service, enabled}));
}

// --- Watch settings: prefs -------------------------------------------------

QVariantList StoandlClient::listWatchPrefs()
{
    // Record: id \t type \t current \t default \t allowed \t flags \t name \t description
    QVariantList rows;
    const QVariantList records = list(QStringLiteral("ListWatchPrefs"));
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        const QString type = f.value(1);
        const QString cur  = f.value(2);
        QVariantMap m;
        m[QStringLiteral("id")]          = f.value(0);
        m[QStringLiteral("type")]        = type;
        m[QStringLiteral("current")]     = cur;
        m[QStringLiteral("currentBool")] = (cur == QStringLiteral("true"));
        m[QStringLiteral("currentInt")]  = cur.toInt();
        m[QStringLiteral("default")]     = f.value(3);
        m[QStringLiteral("allowed")]     = f.value(4).isEmpty() ? QStringList()
                                                                : f.value(4).split(QLatin1Char(','));
        m[QStringLiteral("flags")]       = f.value(5).isEmpty() ? QStringList()
                                                                : f.value(5).split(QLatin1Char(','));
        m[QStringLiteral("name")]        = f.value(6);
        m[QStringLiteral("description")] = f.value(7);
        rows.append(m);
    }
    return rows;
}

QVariantMap StoandlClient::setWatchPref(const QString &id, const QString &value)
{
    return statusMap(callStatus(QStringLiteral("SetWatchPref"), {id, value}));
}

// --- Daemon config, schema-driven (HOOK #10) -------------------------------

QVariantList StoandlClient::configSchema()
{
    // Record: key \t type \t label \t options(comma) \t desc
    QVariantList rows;
    const QVariantList records = list(QStringLiteral("GetConfigSchema"));
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        QVariantMap m;
        m[QStringLiteral("key")]     = f.value(0);
        m[QStringLiteral("type")]    = f.value(1);
        m[QStringLiteral("label")]   = f.value(2);
        m[QStringLiteral("options")] = f.value(3).isEmpty() ? QStringList()
                                                            : f.value(3).split(QLatin1Char(','));
        m[QStringLiteral("desc")]    = f.value(4);
        rows.append(m);
    }
    return rows;
}

QVariantMap StoandlClient::getConfig()
{
    // Record: key \t value
    QVariantMap values;
    const QVariantList records = list(QStringLiteral("GetConfig"));
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        values[f.value(0)] = f.value(1);
    }
    QVariantMap m;
    m[QStringLiteral("values")] = values;
    return m;
}

QVariantMap StoandlClient::setConfig(const QString &key, const QString &value)
{
    return statusMap(callStatus(QStringLiteral("SetConfig"), {key, value}));
}

// --- Notifications ---------------------------------------------------------

QVariantList StoandlClient::notifList()
{
    // Record: name \t muteLabel \t color \t icon \t vibe \t lastNotifiedEpochSeconds
    QVariantList rows;
    const QVariantList records = list(QStringLiteral("NotifList"));
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        const QString mute = f.value(1);
        QVariantMap m;
        m[QStringLiteral("name")]         = f.value(0);
        m[QStringLiteral("mute")]         = mute;
        m[QStringLiteral("muted")]        = (mute != QStringLiteral("never"));
        m[QStringLiteral("color")]        = f.value(2);
        m[QStringLiteral("icon")]         = f.value(3);
        m[QStringLiteral("vibe")]         = f.value(4);
        m[QStringLiteral("lastNotified")] = f.value(5);
        rows.append(m);
    }
    return rows;
}

QVariantMap StoandlClient::notifSetMute(const QString &name, const QString &spec)
{
    return statusMap(callStatus(QStringLiteral("NotifSetMute"), {name, spec}));
}
QVariantMap StoandlClient::notifSetMuteAll(const QString &spec)
{
    return statusMap(callStatus(QStringLiteral("NotifSetMuteAll"), {spec}));
}
QVariantMap StoandlClient::notifSetStyle(const QString &name, const QString &color,
                                         const QString &icon, const QString &vibe)
{
    return statusMap(callStatus(QStringLiteral("NotifSetStyle"), {name, color, icon, vibe}));
}

QVariantMap StoandlClient::notifQuietHours()
{
    // ok:<on|off>\t<from>\t<to>\t<now|off>
    const Status s = callStatus(QStringLiteral("NotifGetQuietHours"));
    QVariantMap m;
    m[QStringLiteral("kind")] = s.kind;
    if (s.kind == QStringLiteral("ok")) {
        m[QStringLiteral("enabled")] = (s.fields.value(0) == QStringLiteral("on"));
        m[QStringLiteral("from")]    = s.fields.value(1);
        m[QStringLiteral("to")]      = s.fields.value(2);
        const QString now = s.fields.value(3);
        m[QStringLiteral("now")]     = (now == QStringLiteral("off")) ? QString() : now;
    }
    return m;
}

QVariantMap StoandlClient::notifSetQuietHours(bool enabled, const QString &from, const QString &to)
{
    return statusMap(callStatus(QStringLiteral("NotifSetQuietHours"), {enabled, from, to}));
}
QVariantMap StoandlClient::notifSetQuietNow(const QString &spec)
{
    return statusMap(callStatus(QStringLiteral("NotifSetQuietNow"), {spec}));
}

QVariantList StoandlClient::notifListFilters()
{
    // Record: pattern \t action(allow|block)
    QVariantList rows;
    const QVariantList records = list(QStringLiteral("NotifListFilters"));
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        QVariantMap m;
        m[QStringLiteral("pattern")] = f.value(0);
        m[QStringLiteral("action")]  = f.value(1);
        rows.append(m);
    }
    return rows;
}

QVariantMap StoandlClient::notifAddFilter(const QString &pattern, const QString &action)
{
    return statusMap(callStatus(QStringLiteral("NotifAddFilter"), {pattern, action}));
}
QVariantMap StoandlClient::notifRemoveFilter(const QString &pattern)
{
    return statusMap(callStatus(QStringLiteral("NotifRemoveFilter"), {pattern}));
}

// --- Health (read-only graphs, HOOK #8) ------------------------------------

QVariantMap StoandlClient::healthSummary()
{
    const Status s = callStatus(QStringLiteral("GetHealthSummary"));
    QVariantMap m;
    m[QStringLiteral("kind")] = s.kind;
    if (s.kind != QStringLiteral("ok")) {
        m[QStringLiteral("msg")] = s.tail;
        return m;
    }
    const QStringList f = s.fields;
    m[QStringLiteral("steps")]          = f.value(0).toInt();
    m[QStringLiteral("stepGoal")]       = f.value(1).toInt();
    m[QStringLiteral("distanceKm")]     = f.value(2);
    m[QStringLiteral("kcal")]           = f.value(3).toInt();
    m[QStringLiteral("activeMin")]      = f.value(4).toInt();
    m[QStringLiteral("stepWeekAvg")]    = f.value(5).toInt();
    m[QStringLiteral("stepTrendPct")]   = f.value(6).toInt();
    m[QStringLiteral("sleepTotalMin")]  = f.value(7).toInt();
    m[QStringLiteral("sleepDeepMin")]   = f.value(8).toInt();
    m[QStringLiteral("sleepLightMin")]  = f.value(9).toInt();
    m[QStringLiteral("sleepRemMin")]    = f.value(10).toInt();
    m[QStringLiteral("sleepAvgMin")]    = f.value(11).toInt();
    m[QStringLiteral("sleepTrendPct")]  = f.value(12).toInt();
    m[QStringLiteral("restingHr")]      = f.value(13).toInt();
    m[QStringLiteral("currentHr")]      = f.value(14).toInt();
    m[QStringLiteral("hrMin")]          = f.value(15).toInt();
    m[QStringLiteral("hrMax")]          = f.value(16).toInt();
    m[QStringLiteral("hrAvailable")]    = (f.value(17) == QStringLiteral("yes"));
    m[QStringLiteral("lastSync")]       = f.value(18);
    return m;
}

QVariantList StoandlClient::healthSeries(const QString &metric)
{
    // Record: label \t value (value empty = no data for that point)
    QVariantList rows;
    const QVariantList records = list(QStringLiteral("GetHealthSeries"), {metric});
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        const QString val = f.value(1);
        QVariantMap m;
        m[QStringLiteral("label")]    = f.value(0);
        m[QStringLiteral("value")]    = val.isEmpty() ? 0 : val.toInt();
        m[QStringLiteral("hasValue")] = !val.isEmpty();
        rows.append(m);
    }
    return rows;
}

// --- polling: focus poll ---------------------------------------------------

void StoandlClient::startWatchPoll()
{
    if (!m_watchTimer->isActive())
        m_watchTimer->start();
    refreshWatches();
}

void StoandlClient::stopWatchPoll()
{
    m_watchTimer->stop();
}

void StoandlClient::refreshWatches()
{
    recheckDaemon();
    Q_EMIT watchesChanged(m_daemonUp ? listWatches() : QVariantList());
}

// --- polling: pair ---------------------------------------------------------

void StoandlClient::startPairPoll()
{
    m_pairElapsedMs = 0;
    if (!m_pairTimer->isActive())
        m_pairTimer->start();
}

void StoandlClient::stopPairPoll()
{
    m_pairTimer->stop();
}

void StoandlClient::pollPairOnce()
{
    m_pairElapsedMs += PAIR_INTERVAL_MS;
    if (m_pairElapsedMs > PAIR_TIMEOUT_MS) {
        stopPairPoll();
        Q_EMIT pairStatus(QStringLiteral("timeout"), QStringLiteral("Pairing timed out"));
        return;
    }
    const Status s = callStatus(QStringLiteral("PairStatus"));
    Q_EMIT pairStatus(s.kind, s.tail);
    // Terminal states per dbus-interface.md: ok / error / timeout.
    if (s.kind == QStringLiteral("ok") || s.kind == QStringLiteral("error")
        || s.kind == QStringLiteral("timeout"))
        stopPairPoll();
}

// --- daemon lifecycle ------------------------------------------------------

void StoandlClient::recheckDaemon()
{
    QDBusMessage m = QDBusMessage::createMethodCall(DBUS_SERVICE, DBUS_PATH, DBUS_IFACE,
                                                    QStringLiteral("NameHasOwner"));
    m.setArguments({ QString::fromLatin1(SERVICE) });
    const QDBusMessage r = m_bus.call(m, QDBus::Block, NAME_TIMEOUT_MS);
    const bool up = (r.type() != QDBusMessage::ErrorMessage) && r.arguments().value(0).toBool();
    if (up != m_daemonUp) {
        m_daemonUp = up;
        Q_EMIT daemonUpChanged();
    }
}

void StoandlClient::onNameOwnerChanged(const QString &name, const QString &, const QString &newOwner)
{
    if (name != QLatin1String(SERVICE))
        return;
    const bool up = !newOwner.isEmpty();
    if (up != m_daemonUp) {
        m_daemonUp = up;
        Q_EMIT daemonUpChanged();
    }
}

bool StoandlClient::startDaemon()
{
    // The daemon is NOT D-Bus-activated — start the systemd *user* service.
    const bool launched = QProcess::startDetached(QStringLiteral("systemctl"),
                                                  { QStringLiteral("--user"),
                                                    QStringLiteral("start"),
                                                    QStringLiteral("stoandl") });
    // NameOwnerChanged should fire, but re-probe a couple of times as a fallback.
    QTimer::singleShot(1500, this, &StoandlClient::recheckDaemon);
    QTimer::singleShot(4000, this, &StoandlClient::recheckDaemon);
    return launched;
}
