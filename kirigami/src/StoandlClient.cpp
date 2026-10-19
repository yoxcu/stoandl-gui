#include "StoandlClient.h"

#include <QTimer>
#include <QProcess>
#include <QUrl>
#include <QDesktopServices>
#include <QDateTime>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QDBusMessage>
#include <QDBusPendingCall>
#include <QDBusPendingReply>
#include <QDBusPendingCallWatcher>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QJsonValue>
#include <QLoggingCategory>
#include <QSet>
#include <QRegularExpression>
#include <QPointer>
#include <QJSEngine>
#include <QQmlIncubationController>

#include <memory>

#include <algorithm>
#include <limits>

namespace {
// Service contract — the daemon's docs/dbus-interface.md §"Service summary".
constexpr auto SERVICE = "de.yoxcu.stoandl";
constexpr auto PATH    = "/de/yoxcu/stoandl";
constexpr auto IFACE   = "de.yoxcu.stoandl.Control";
// Held by a running daemon from its first moment (the public SERVICE name only once it is ready); not for
// calls, only to tell "starting" from "not running".
constexpr auto INSTANCE = "de.yoxcu.stoandl.Instance";

// org.freedesktop.DBus (the bus daemon itself) — for NameHasOwner / NameOwnerChanged.
constexpr auto DBUS_SERVICE = "org.freedesktop.DBus";
constexpr auto DBUS_PATH    = "/org/freedesktop/DBus";
constexpr auto DBUS_IFACE   = "org.freedesktop.DBus";

constexpr int CALL_TIMEOUT_MS = 10000;  // ordinary request/response
// The calls that wait on the watch or the network (a sync, a search, a launch, a firmware download,
// a transcription): as long as the CLI waits for them.
constexpr int SLOW_CALL_TIMEOUT_MS = 120000;
constexpr int FIND_TIMEOUT_MS = 20000;  // FindWatch may linger daemon-side
constexpr int NAME_TIMEOUT_MS = 3000;
// appIcon(): how long a "no icon" answer is reused before a row asks again (the daemon can fetch an
// app's .pbw after the LockerChanged that listed it, and has the icon from then on).
constexpr qint64 NONE_ICON_TRUST_MS = 60000;
// CheckFirmware runs asynchronously, so it can outwait the daemon's own HTTP timeouts (15 s connect,
// 30 s request) instead of giving up at the ordinary 10 s and leaving the download running.
constexpr int FW_CHECK_TIMEOUT_MS = 60000;
// How long a failed check (a daemon error: answer or a D-Bus error such as the timeout above) is
// reused for an unchanged watch key: the daemon keeps a failed lookup that long too (ERROR_TTL_MS),
// so a re-ask after it reaches the source again, and a failure at boot (network not up yet) heals.
constexpr qint64 FW_ERROR_REUSE_MS = 60000;

// Pair/Repair poll: 1.5 s cadence, 145 s ceiling (the daemon's dbus-interface.md §Long-running operations).
constexpr int PAIR_INTERVAL_MS = 1500;
constexpr int PAIR_TIMEOUT_MS  = 145000;

// Watch poll of ListWatches: a 20 s safety-net cadence while a watch screen is foreground.
// Live updates now arrive via the WatchesChanged signal; this poll stays as (a) the carrier
// for the BluetoothStatus poll and (b) the missed-signal fallback (the daemon isn't
// D-Bus-activated, so a late/reconnecting client can miss a WatchesChanged).
constexpr int WATCH_INTERVAL_MS = 20000;

// Firmware flash poll: 0.8 s cadence, 600 s ceiling.
constexpr int FW_INTERVAL_MS = 800;
constexpr int FW_TIMEOUT_MS  = 600000;

// Watch tasks (sideload, screenshot, logs, core dump): TaskChanged reports them; this poll of TaskStatus is
// the missed-signal fallback, and a task still running after the ceiling is reported as timed out.
constexpr int TASK_POLL_MS = 2000;
constexpr qint64 TASK_TIMEOUT_MS = 600000;

// Language install poll: 3 s watchdog cadence, 180 s ceiling. The LanguageProgress signal now
// carries the live %, so this poll is relaxed from a chatty 0.6 s to a watchdog tick — it stays
// as the reboot/disconnect watchdog + terminal-state catch (and the missed-signal fallback).
constexpr int LANG_INTERVAL_MS = 3000;
constexpr int LANG_TIMEOUT_MS  = 180000;
} // namespace

// Failures are logged to the terminal (stderr) as well as shown as in-app toasts —
// run the GUI from a shell to see them. Warnings are on by default; silence with
//   QT_LOGGING_RULES="stoandl.warning=false"   or get the full call trace with
//   QT_LOGGING_RULES="stoandl.debug=true"
Q_LOGGING_CATEGORY(lcStoandl, "stoandl", QtWarningMsg)

// --- parsing (pure, file-local) --------------------------------------------

namespace {
using Status = StoandlClient::Status;

Status parseStatus(const QString &s)
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

QVariantMap statusMap(const Status &s)
{
    QVariantMap m;
    m[QStringLiteral("kind")]     = s.kind;
    m[QStringLiteral("tail")]     = s.tail;
    m[QStringLiteral("fields")]   = s.fields;
    m[QStringLiteral("ok")]       = s.ok();
    m[QStringLiteral("notready")] = (s.kind == QStringLiteral("notready"));
    return m;
}

// The leading run of digits as an int ("42%" -> 42, "3000 ms" -> 3000), -1 when there is none.
int parsePercent(const QString &s)
{
    QString num;
    bool started = false;
    for (const QChar c : s) {
        if (c.isDigit()) { num.append(c); started = true; }
        else if (started) break;
    }
    return num.isEmpty() ? -1 : num.toInt();
}

// A `requires` column (GetConfigSchema 13, ListWatchPrefs 10): alternatives joined by '|', each
// `key=value` or `key!=value` -> [{key, negate, value}]. The row matters while ANY of them holds; none
// (an empty column, or an older daemon without it) means always.
QVariantList parseRequires(const QString &raw)
{
    QVariantList out;
    for (const QString &alt : raw.split(QLatin1Char('|'), Qt::SkipEmptyParts)) {
        const int ne = alt.indexOf(QStringLiteral("!="));
        const int eq = ne >= 0 ? ne : alt.indexOf(QLatin1Char('='));
        if (eq <= 0)
            continue;
        QVariantMap m;
        m[QStringLiteral("key")]    = alt.left(eq).trimmed();
        m[QStringLiteral("negate")] = ne >= 0;
        m[QStringLiteral("value")]  = alt.mid(eq + (ne >= 0 ? 2 : 1));
        out.append(m);
    }
    return out;
}

// What a failed D-Bus call means, in words for a toast or a page: the one place the GUI words D-Bus
// errors (callers log the raw name and message). `starting` = the daemon holds its instance name but not
// yet the public one (it takes that last, once everything is up).
QString errorText(const QDBusMessage &reply, bool starting)
{
    const QString name = reply.errorName();
    const auto is = [&name](const char *suffix) {
        return name == QLatin1String("org.freedesktop.DBus.Error.") + QLatin1String(suffix);
    };
    if (is("NoReply") || is("Timeout") || is("TimedOut"))
        return QStringLiteral("stoandl didn't answer in time (it may still be working)");
    if (is("UnknownMethod") || is("UnknownInterface"))
        return QStringLiteral("Your stoandl daemon is older than this app");
    if (is("ServiceUnknown") || is("NameHasNoOwner") || is("UnknownObject"))
        return starting ? QStringLiteral("stoandl is still starting — try again in a moment")
                        : QStringLiteral("stoandl isn't running");
    return reply.errorMessage();
}

void logDbusError(const QString &method, const QDBusMessage &reply)
{
    qCWarning(lcStoandl).noquote().nospace()
        << "D-Bus " << method << " failed: " << reply.errorName() << " — " << reply.errorMessage();
}

// A reply as a Status; failures (D-Bus errors, daemon error/failed/timeout kinds) are logged. A D-Bus
// error becomes kind `error` with errorText() as its tail.
Status statusFromReply(const QString &method, const QDBusMessage &reply, bool starting = false)
{
    if (reply.type() == QDBusMessage::ErrorMessage) {
        logDbusError(method, reply);
        return { QStringLiteral("error"), errorText(reply, starting), {} };
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

// An `as` reply as records, one QStringList per tab-split row; a D-Bus error is logged and gives none.
QVariantList recordsFromReply(const QString &method, const QDBusMessage &reply)
{
    QVariantList out;
    if (reply.type() == QDBusMessage::ErrorMessage) {
        logDbusError(method, reply);
        return out;
    }
    const QStringList rows = reply.arguments().value(0).toStringList();
    for (const QString &row : rows)
        out.append(QVariant(row.split(QLatin1Char('\t'))));
    return out;
}
} // namespace


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
    // What the Watch page is told, after normalisation (QT_LOGGING_RULES="stoandl.debug=true").
    // The smoke harness prints it unconditionally.
    connect(this, &StoandlClient::firmwareStatus, this, [](const QString &kind, int percent, const QString &detail) {
        if (smokeMs() > 0)
            qInfo().noquote().nospace() << "stoandl-smoke: firmwareStatus → " << kind << " " << percent << " " << detail;
        else
            qCDebug(lcStoandl).noquote().nospace() << "firmwareStatus → " << kind << " " << percent << " " << detail;
    });
    // A finished flash makes the cached CheckFirmware answer describe the old firmware: drop it (the
    // banner goes) but keep its watch key, so the check comes again when the rebooted watch's state
    // changes, as before, not while the old link is still listed.
    connect(this, &StoandlClient::firmwareStatus, this, [this](const QString &kind, int, const QString &) {
        if (kind == QStringLiteral("success"))
            clearFirmwareInfo(false);
    });

    m_langTimer = new QTimer(this);
    m_langTimer->setInterval(LANG_INTERVAL_MS);
    connect(m_langTimer, &QTimer::timeout, this, &StoandlClient::languagePollOnce);

    m_muteEndTimer = new QTimer(this);
    m_muteEndTimer->setSingleShot(true);
    connect(m_muteEndTimer, &QTimer::timeout, this, [this] { setMutedUntil(0); });

    m_taskTimer = new QTimer(this);
    m_taskTimer->setInterval(TASK_POLL_MS);
    connect(m_taskTimer, &QTimer::timeout, this, &StoandlClient::pollTasks);

    // React to the daemon coming up / going down without polling NameHasOwner.
    m_bus.connect(DBUS_SERVICE, DBUS_PATH, DBUS_IFACE, QStringLiteral("NameOwnerChanged"),
                  this, SLOT(onNameOwnerChanged(QString, QString, QString)));

    // Reactive signals on de.yoxcu.stoandl.Control — instant UI on connect/flash/locker change.
    // These augment (don't replace) polling: the daemon isn't D-Bus-activated, so a late or
    // reconnecting client can miss a signal — the slow watch poll + the daemonUp re-sync are the
    // missed-signal safety net. Connecting before the name is owned is fine: QDBus installs a match
    // rule and the signals arrive once the service appears (no reconnect-on-daemonUp needed).
    m_bus.connect(SERVICE, PATH, IFACE, QStringLiteral("WatchesChanged"),
                  this, SLOT(onWatchesChanged()));
    m_bus.connect(SERVICE, PATH, IFACE, QStringLiteral("FirmwareProgress"),
                  this, SLOT(onFirmwareProgress(QString, int, QString)));
    m_bus.connect(SERVICE, PATH, IFACE, QStringLiteral("LockerChanged"),
                  this, SLOT(onLockerChanged()));
    m_bus.connect(SERVICE, PATH, IFACE, QStringLiteral("CalendarsChanged"),
                  this, SLOT(onCalendarsChanged()));
    m_bus.connect(SERVICE, PATH, IFACE, QStringLiteral("LanguageProgress"),
                  this, SLOT(onLanguageProgress(QString, int, QString)));
    m_bus.connect(SERVICE, PATH, IFACE, QStringLiteral("ExtensionsChanged"),
                  this, SLOT(onExtensionsChanged()));
    m_bus.connect(SERVICE, PATH, IFACE, QStringLiteral("PluginsChanged"),
                  this, SLOT(onPluginsChanged()));
    m_bus.connect(SERVICE, PATH, IFACE, QStringLiteral("PermissionRequestsChanged"),
                  this, SLOT(onPluginsChanged()));
    m_bus.connect(SERVICE, PATH, IFACE, QStringLiteral("ExtensionStateChanged"),
                  this, SLOT(onExtensionStateChanged(QString, QString)));
    m_bus.connect(SERVICE, PATH, IFACE, QStringLiteral("ConfigChanged"),
                  this, SLOT(onConfigChanged(QString)));
    m_bus.connect(SERVICE, PATH, IFACE, QStringLiteral("TaskChanged"),
                  this, SLOT(onTaskChanged(QString, QString)));

    recheckDaemon();
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
    return statusFromReply(method, m_bus.call(methodCall(method, args), QDBus::Block, CALL_TIMEOUT_MS),
                           m_instanceUp);
}

// --- generic ---------------------------------------------------------------

QVariantMap StoandlClient::call(const QString &method, const QVariantList &args)
{
    return statusMap(callStatus(method, args));
}

QVariantList StoandlClient::list(const QString &method, const QVariantList &args)
{
    return recordsFromReply(method, m_bus.call(methodCall(method, args), QDBus::Block, CALL_TIMEOUT_MS));
}

// --- typed wrappers: Watch -------------------------------------------------

namespace {
QVariant watchRows(const QVariantList &records)
{
    QVariantList rows;
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        QVariantMap m;
        m[QStringLiteral("name")]      = f.value(0);
        m[QStringLiteral("state")]     = f.value(1);
        m[QStringLiteral("battery")]   = f.value(2);
        m[QStringLiteral("transport")] = f.value(3);   // HOOK #4: ble|classic, empty when disconnected
        m[QStringLiteral("connected")] = (f.value(1) == QStringLiteral("connected"));
        // Connected in its recovery firmware (PRF): only the firmware flash, core dump and logs work.
        m[QStringLiteral("recovery")]  = (f.value(1) == QStringLiteral("recovery"));
        rows.append(m);
    }
    return rows;
}
} // namespace

QVariantList StoandlClient::listWatches()
{
    return read(QStringLiteral("listWatches")).toList();
}

QVariantMap StoandlClient::battery()                       { return statusMap(callStatus(QStringLiteral("Battery"))); }

namespace {
QVariant batteryInsightsMap(const Status &s)
{
    QVariantMap m = statusMap(s);
    if (s.ok()) {
        // ok:name\tlevel\tcharging\tdischargePerHour\thoursRemaining\tchargeSessions7d\t
        //    lastChargedEpoch\tmin24h\tmax24h\tsampleCount\tvoltage\tsource
        const QStringList f = s.fields;
        m[QStringLiteral("name")]             = f.value(0);
        m[QStringLiteral("level")]            = f.value(1).toDouble();
        m[QStringLiteral("charging")]         = (f.value(2) == QStringLiteral("1"));
        m[QStringLiteral("dischargePerHour")] = f.value(3).toDouble();
        m[QStringLiteral("hoursRemaining")]   = f.value(4);   // string; empty when unknown/charging
        m[QStringLiteral("chargeSessions")]   = f.value(5).toInt();
        m[QStringLiteral("lastChargedEpoch")] = f.value(6).toLongLong();
        m[QStringLiteral("min24h")]           = f.value(7).toDouble();
        m[QStringLiteral("max24h")]           = f.value(8).toDouble();
        m[QStringLiteral("sampleCount")]      = f.value(9).toInt();
        m[QStringLiteral("voltage")]          = f.value(10);  // string; empty for the gatt source
        m[QStringLiteral("source")]           = f.value(11);
    }
    return m;
}
} // namespace

QVariantMap StoandlClient::batteryInsights(const QString &watch)
{
    return read(QStringLiteral("batteryInsights"), {watch}).toMap();
}

namespace {
QVariant batteryHistoryRows(const Status &s)
{
    QVariantList out;
    if (!s.ok())
        return out;
    // tail = newline-joined "ts\tlevel\tsource\tvoltage" rows (empty body = no samples yet).
    const QStringList rows = s.tail.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    out.reserve(rows.size());
    for (const QString &row : rows) {
        const QStringList f = row.split(QLatin1Char('\t'));
        QVariantMap p;
        p[QStringLiteral("ts")]      = f.value(0).toLongLong();
        p[QStringLiteral("level")]   = f.value(1).toDouble();
        p[QStringLiteral("source")]  = f.value(2);
        p[QStringLiteral("voltage")] = f.value(3);   // string; empty for the gatt source
        out.append(p);
    }
    return out;
}
} // namespace

QVariantList StoandlClient::batteryHistory(const QString &watch, qlonglong sinceEpoch)
{
    return read(QStringLiteral("batteryHistory"), {watch, sinceEpoch}).toList();
}

namespace {
QVariant batteryActivityRows(const Status &s)
{
    QVariantList out;
    if (!s.ok())
        return out;
    // tail = newline-joined "ts\tdrop\tnotif\tnotifDnd" rows (empty body = no records yet).
    const QStringList rows = s.tail.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    out.reserve(rows.size());
    for (const QString &row : rows) {
        const QStringList f = row.split(QLatin1Char('\t'));
        QVariantMap p;
        p[QStringLiteral("ts")]       = f.value(0).toLongLong();
        p[QStringLiteral("drop")]     = f.value(1).toDouble();      // SoC % consumed this interval
        p[QStringLiteral("notif")]    = f.value(2).toInt();
        p[QStringLiteral("notifDnd")] = f.value(3).toInt();
        out.append(p);
    }
    return out;
}
} // namespace

QVariantList StoandlClient::batteryActivity(const QString &watch, qlonglong sinceEpoch)
{
    return read(QStringLiteral("batteryActivity"), {watch, sinceEpoch}).toList();
}

namespace {
QVariant batteryPowerRows(const Status &s)
{
    QVariantList out;
    if (!s.ok())
        return out;
    // tail = newline-joined "category\testDrainPct\tsharePct" slices (largest share first).
    const QStringList rows = s.tail.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    out.reserve(rows.size());
    for (const QString &row : rows) {
        const QStringList f = row.split(QLatin1Char('\t'));
        QVariantMap p;
        p[QStringLiteral("category")]    = f.value(0);
        p[QStringLiteral("estDrainPct")] = f.value(1).toDouble();   // % battery drained (0 = unanchored)
        p[QStringLiteral("share")]       = f.value(2).toDouble();   // percent share of the modeled drain
        out.append(p);
    }
    return out;
}
} // namespace

QVariantList StoandlClient::batteryPower(const QString &watch, qlonglong sinceEpoch)
{
    return read(QStringLiteral("batteryPower"), {watch, sinceEpoch}).toList();
}

QVariantMap StoandlClient::connectWatch(const QString &n)  { return statusMap(callStatus(QStringLiteral("Connect"), {n})); }
QVariantMap StoandlClient::disconnectWatch()               { return statusMap(callStatus(QStringLiteral("Disconnect"))); }
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

namespace {
QVariant appRows(const QVariantList &records)
{
    // Record: uuid \t type \t order \t flags \t title \t developer \t version
    // flags is a comma-joined subset of {active, sideloaded, config, system}.
    QVariantList rows;
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
        m[QStringLiteral("version")]    = f.value(6);
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
} // namespace

QVariantList StoandlClient::listApps()
{
    return read(QStringLiteral("listApps")).toList();
}

namespace {
QVariant appIconUrl(const Status &s)
{
    // GetAppIcon(uuid) -> "ok:<abs png path>" | "none:" | "notready:" | "error:<msg>".
    // The daemon is co-located, so the path is a local file; hand the QML a file:// URL it can
    // load straight into an Image. Empty string = no icon (delegate uses its generic fallback).
    if (s.kind != QStringLiteral("ok") || s.tail.isEmpty())
        return QString();
    return QUrl::fromLocalFile(s.tail).toString();
}
} // namespace

QString StoandlClient::appIcon(const QString &uuid)
{
    if (uuid.isEmpty())
        return QString();
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const auto it = m_icons.constFind(uuid);
    const bool known = it != m_icons.constEnd();
    const QString url = known ? it->url : QString();
    if ((!known || (url.isEmpty() && now - it->answeredMs > NONE_ICON_TRUST_MS))
        && !m_iconPending.contains(uuid)) {
        m_iconPending.insert(uuid);
        readAsync(QStringLiteral("appIcon"), {uuid}, nullptr, [this, uuid](const QVariant &v) {
            m_iconPending.remove(uuid);
            const QString answer = v.toString();
            m_icons.insert(uuid, { answer, QDateTime::currentMSecsSinceEpoch() });
            Q_EMIT appIconChanged(uuid, answer);
        });
    }
    return url;
}

QVariantMap StoandlClient::launchApp(const QString &id) { return read(QStringLiteral("launchApp"), {id}).toMap(); }
QVariantMap StoandlClient::removeApp(const QString &id) { return statusMap(callStatus(QStringLiteral("RemoveApp"), {id})); }
QVariantMap StoandlClient::setAppOrder(const QString &id, int order) { return statusMap(callStatus(QStringLiteral("SetAppOrder"), {id, order})); }
QVariantMap StoandlClient::restoreSystemAppOrder() { return statusMap(callStatus(QStringLiteral("RestoreSystemAppOrder"))); }

QVariantMap StoandlClient::sideloadApp(const QUrl &fileUrl)
{
    // Paths are absolute and daemon-side; the GUI is co-located, so the local
    // path of the chosen file is the daemon-side path.
    const QString path = fileUrl.toLocalFile();
    if (path.isEmpty())
        return statusMap({ QStringLiteral("error"), QStringLiteral("not a local file"), {} });
    return startTask(QStringLiteral("sideload"), QStringLiteral("SideloadApp"), {path});
}

QVariantMap StoandlClient::openConfig(const QString &id)
{
    // OpenConfig returns "" (no config page) or a loopback URL the daemon serves the
    // page from; Save on the page goes straight back to the app, so we only open it.
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

    const QString url = reply.arguments().value(0).toString();
    m[QStringLiteral("kind")]   = url.isEmpty() ? QStringLiteral("none") : QStringLiteral("ok");
    m[QStringLiteral("url")]    = url;
    m[QStringLiteral("msg")]    = QString();
    m[QStringLiteral("opened")] = !url.isEmpty() && QDesktopServices::openUrl(QUrl(url));
    return m;
}

void StoandlClient::refreshApps()
{
    const quint64 seq = ++m_appsSeq;
    if (!m_daemonUp) {
        Q_EMIT appsChanged({});
        return;
    }
    readAsync(QStringLiteral("listApps"), {}, nullptr, [this, seq](const QVariant &rows) {
        if (seq == m_appsSeq)
            Q_EMIT appsChanged(rows.toList());
    });
}

// --- typed wrappers: Plugins (extensions) ----------------------------------

namespace {
QVariant extRows(const QVariantList &records)
{
    // Record (HOOK #7): name \t installed|missing \t enabled|disabled \t
    //                   running|stopped \t config(none|schema) \t description \t author \t version
    // (StoandlClient::withExtState() adds `runtimeState`.)
    QVariantList rows;
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        const QString cfg = f.value(4);
        QVariantMap m;
        m[QStringLiteral("name")]        = f.value(0);
        m[QStringLiteral("installed")]   = (f.value(1) == QStringLiteral("installed"));
        m[QStringLiteral("enabled")]     = (f.value(2) == QStringLiteral("enabled"));
        m[QStringLiteral("running")]     = (f.value(3) == QStringLiteral("running"));
        m[QStringLiteral("config")]      = cfg.isEmpty() ? QStringLiteral("none") : cfg;
        m[QStringLiteral("hasConfig")]   = (cfg == QStringLiteral("schema"));
        m[QStringLiteral("description")] = f.value(5);
        m[QStringLiteral("author")]      = f.value(6);
        m[QStringLiteral("version")]     = f.value(7);
        rows.append(m);
    }
    return rows;
}
} // namespace

QVariantList StoandlClient::withExtState(QVariantList rows)
{
    QSet<QString> seen;
    for (QVariant &row : rows) {
        QVariantMap m = row.toMap();
        const QString name = m.value(QStringLiteral("name")).toString();
        seen.insert(name);
        // Merge the live ExtensionStateChanged override (ready/exited/quarantined). The polled
        // `running|stopped` can't see a quarantine (the daemon keeps a quarantined ext in its
        // `running` map), so an override wins for the QML's `runtimeState` field. Map a bare
        // `ready` back to the polled running/stopped so it doesn't override with a less specific
        // word; keep `exited`/`quarantined` as-is (those are the whole point of this signal).
        const QString override = m_extState.value(name);
        QString runtimeState;
        if (override == QStringLiteral("quarantined") || override == QStringLiteral("exited"))
            runtimeState = override;
        else
            runtimeState = m.value(QStringLiteral("running")).toBool() ? QStringLiteral("running")
                                                                        : QStringLiteral("stopped");
        m[QStringLiteral("runtimeState")] = runtimeState;
        row = m;
    }
    // Drop overrides for extensions ExtList no longer reports (uninstalled / renamed away).
    for (auto it = m_extState.begin(); it != m_extState.end();) {
        if (seen.contains(it.key()))
            ++it;
        else
            it = m_extState.erase(it);
    }
    return rows;
}

QVariantList StoandlClient::extList()
{
    return withExtState(read(QStringLiteral("extList")).toList());
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
    const quint64 seq = ++m_extSeq;
    if (!m_daemonUp) {
        Q_EMIT extensionsChanged({});
        return;
    }
    readAsync(QStringLiteral("extList"), {}, nullptr, [this, seq](const QVariant &rows) {
        if (seq == m_extSeq)
            Q_EMIT extensionsChanged(withExtState(rows.toList()));
    });
}

// --- typed wrappers: Sync --------------------------------------------------

QVariantMap StoandlClient::syncWeather()  { return read(QStringLiteral("syncWeather")).toMap(); }

namespace {
// `ok:` carries one `name\tlat\tlon\tregion\tcountry` record per line, so the tail is split by line here
// rather than by statusMap's single-record `fields`.
QVariant placesMap(const Status &st)
{
    QVariantMap m = statusMap(st);
    QVariantList places;
    if (st.ok()) {
        const QStringList lines = st.tail.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
        for (const QString &line : lines) {
            const QStringList f = line.split(QLatin1Char('\t'));
            if (f.size() < 3)
                continue;
            QVariantMap p;
            p[QStringLiteral("name")]    = f.at(0);
            p[QStringLiteral("lat")]     = f.at(1).toDouble();
            p[QStringLiteral("lon")]     = f.at(2).toDouble();
            p[QStringLiteral("region")]  = f.value(3);
            p[QStringLiteral("country")] = f.value(4);
            places.append(p);
        }
    }
    m[QStringLiteral("places")] = places;
    return m;
}
} // namespace

QVariantMap StoandlClient::searchWeatherPlace(const QString &query)
{
    return read(QStringLiteral("searchWeatherPlace"), {query}).toMap();
}

QVariantMap StoandlClient::addWeatherLocation(const QString &name, double lat, double lon)
{
    return statusMap(callStatus(QStringLiteral("AddWeatherLocation"), {name, lat, lon}));
}
QVariantMap StoandlClient::syncCalendar() { return read(QStringLiteral("syncCalendar")).toMap(); }
QVariantMap StoandlClient::syncHealth()   { return read(QStringLiteral("syncHealth")).toMap(); }

namespace {
QVariant healthProfileMap(const QVariantList &rows)
{
    // GetHealthProfile() -> [ [key, value(, allowed)], ... ]  →  { key: value, ..., _allowed: { key: [values] } }
    // A third field is the |-joined values SetHealthProfile accepts for that key right now.
    QVariantMap m;
    QVariantMap allowed;
    for (const QVariant &r : rows) {
        const QStringList f = r.toStringList();
        if (f.size() >= 2)
            m[f.value(0)] = f.value(1);
        if (f.size() >= 3 && !f.value(2).isEmpty())
            allowed[f.value(0)] = f.value(2).split(QLatin1Char('|'));
    }
    if (!allowed.isEmpty())
        m[QStringLiteral("_allowed")] = allowed;
    return m;
}
} // namespace

QVariantMap StoandlClient::healthProfile()
{
    return read(QStringLiteral("healthProfile")).toMap();
}

QVariantMap StoandlClient::setHealthProfile(const QString &key, const QString &value)
{
    return statusMap(callStatus(QStringLiteral("SetHealthProfile"), {key, value}));
}

namespace {
QVariant calendarRows(const QVariantList &records)
{
    // Record: id \t name \t enabled|disabled \t accountId  (accountId groups calendars under a source)
    QVariantList rows;
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        QVariantMap m;
        m[QStringLiteral("id")]        = f.value(0);
        m[QStringLiteral("name")]      = f.value(1);
        m[QStringLiteral("enabled")]   = (f.value(2) == QStringLiteral("enabled"));
        m[QStringLiteral("accountId")] = f.value(3);
        rows.append(m);
    }
    return rows;
}

QVariant calendarSourceRows(const QVariantList &records)
{
    // Record: id \t type \t url \t username \t label \t lastError \t lastSync  (the password is write-only,
    // never returned; lastError is empty while the source reads fine, lastSync the epoch seconds of its last
    // good read or empty — both appended, so empty from an older daemon)
    QVariantList rows;
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        QVariantMap m;
        m[QStringLiteral("id")]        = f.value(0);
        m[QStringLiteral("type")]      = f.value(1);
        m[QStringLiteral("url")]       = f.value(2);
        m[QStringLiteral("username")]  = f.value(3);
        m[QStringLiteral("label")]     = f.value(4);
        m[QStringLiteral("lastError")] = f.value(5);
        m[QStringLiteral("lastSync")]  = f.value(6).toLongLong();
        rows.append(m);
    }
    return rows;
}
} // namespace

QVariantList StoandlClient::listCalendars()
{
    return read(QStringLiteral("listCalendars")).toList();
}

QVariantMap StoandlClient::setCalendarEnabled(const QString &id, bool enabled)
{
    return statusMap(callStatus(QStringLiteral("SetCalendarEnabled"), {id, enabled}));
}

void StoandlClient::refreshCalendars()
{
    const quint64 seq = ++m_calendarsSeq;
    if (!m_daemonUp) {
        Q_EMIT calendarsChanged({});
        return;
    }
    readAsync(QStringLiteral("listCalendars"), {}, nullptr, [this, seq](const QVariant &rows) {
        if (seq == m_calendarsSeq)
            Q_EMIT calendarsChanged(rows.toList());
    });
}

QVariantList StoandlClient::listCalendarSources()
{
    return read(QStringLiteral("listCalendarSources")).toList();
}

QVariantMap StoandlClient::addCalendarSource(const QString &type, const QString &url,
                                             const QString &username, const QString &password)
{
    return statusMap(callStatus(QStringLiteral("AddCalendarSource"), {type, url, username, password}));
}

QVariantMap StoandlClient::updateCalendarSource(const QString &id, const QString &url,
                                                const QString &username, const QString &password)
{
    return statusMap(callStatus(QStringLiteral("UpdateCalendarSource"), {id, url, username, password}));
}

QVariantMap StoandlClient::removeCalendarSource(const QString &id)
{
    return statusMap(callStatus(QStringLiteral("RemoveCalendarSource"), {id}));
}

// --- typed wrappers: System / firmware -------------------------------------

QVariantMap StoandlClient::firmwareInfoMap(const Status &s)
{
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

void StoandlClient::requestFirmwareCheck(const QString &watchKey)
{
    m_fwWantedKey = watchKey;
    // A call in flight answers for its own key; the reply handler issues the next one if the key moved.
    if (!m_daemonUp || m_fwCheckInFlight)
        return;
    if (m_fwHaveInfo && m_fwInfoKey == watchKey
        && !(m_fwInfo.value(QStringLiteral("kind")).toString() == QLatin1String("error")
             && m_fwInfoAge.hasExpired(FW_ERROR_REUSE_MS)))
        return;
    startFirmwareCheck(false);
}

void StoandlClient::forceFirmwareCheck()
{
    if (!m_daemonUp)
        return;
    if (m_fwCheckInFlight) {
        m_fwForceQueued = true;
        return;
    }
    startFirmwareCheck(true);
}

void StoandlClient::startFirmwareCheck(bool force)
{
    // An explicit check also bypasses the daemon's own cache (3 h per source/board/firmware), when the
    // daemon has CheckFirmwareForce; an older one only has CheckFirmware.
    const bool useForce = force && !m_fwForceUnsupported;
    const QString method = useForce ? QStringLiteral("CheckFirmwareForce") : QStringLiteral("CheckFirmware");
    const QString key = m_fwWantedKey;
    const quint64 generation = m_fwGeneration;
    m_fwCheckInFlight = true;
    m_fwForceQueued = false;
    Q_EMIT firmwareInfoChanged();

    const QDBusPendingCall pc = m_bus.asyncCall(methodCall(method, {}), FW_CHECK_TIMEOUT_MS);
    auto *w = new QDBusPendingCallWatcher(pc, this);
    connect(w, &QDBusPendingCallWatcher::finished, this,
            [this, method, key, generation, useForce](QDBusPendingCallWatcher *self) {
        self->deleteLater();
        m_fwCheckInFlight = false;
        const QDBusMessage reply = self->reply();
        if (useForce && reply.type() == QDBusMessage::ErrorMessage
            && reply.errorName() == QLatin1String("org.freedesktop.DBus.Error.UnknownMethod")) {
            m_fwForceUnsupported = true;
            if (generation == m_fwGeneration && m_daemonUp) {
                startFirmwareCheck(false);
                return;
            }
        }
        // A reply from before the cache was dropped (daemon restart, a finished flash) is stale.
        if (generation == m_fwGeneration) {
            m_fwInfo = firmwareInfoMap(statusFromReply(method, reply, m_instanceUp));
            m_fwInfoKey = key;
            m_fwHaveInfo = true;
            m_fwInfoAge.start();
        }
        const bool again = m_daemonUp
            && (m_fwForceQueued || !m_fwHaveInfo || m_fwInfoKey != m_fwWantedKey);
        if (again)
            startFirmwareCheck(m_fwForceQueued);
        else
            Q_EMIT firmwareInfoChanged();
    });
}

void StoandlClient::clearFirmwareInfo(bool forgetKey)
{
    ++m_fwGeneration;
    m_fwInfo.clear();
    m_fwForceQueued = false;
    if (forgetKey) {
        m_fwHaveInfo = false;
        m_fwInfoKey.clear();
    }
    Q_EMIT firmwareInfoChanged();
}

QVariantMap StoandlClient::updateFirmware()
{
    return read(QStringLiteral("updateFirmware")).toMap();   // afterRead() starts the flash poll
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
    m_fwViaRecovery = false;
    m_fwPrfVersion.clear();
    if (!m_fwTimer->isActive())
        m_fwTimer->start();
    opPollsChanged();
}

void StoandlClient::stopFirmwarePoll() { m_fwTimer->stop(); opPollsChanged(); }

void StoandlClient::endFirmwareOp()
{
    stopFirmwarePoll();
    // Clear the activity/recovery state so a trailing idle/notready frame (the daemon resetting its
    // firmware state once the watch reconnects) hits the no-flicker guard in emitFirmwareStatus
    // instead of re-opening the "Updating firmware" banner.
    m_fwSeenActivity = false;
    m_fwViaRecovery = false;
    m_fwPrfVersion.clear();
}

void StoandlClient::firmwarePollOnce()
{
    m_fwElapsedMs += FW_INTERVAL_MS;
    if (m_fwElapsedMs > FW_TIMEOUT_MS) {
        endFirmwareOp();
        Q_EMIT firmwareStatus(QStringLiteral("timeout"), -1, QStringLiteral("Flash timed out"));
        return;
    }
    const Status s = callStatus(QStringLiteral("FirmwareStatus"));
    const int pct = (s.kind == QStringLiteral("inprogress")) ? parsePercent(s.tail) : -1;
    emitFirmwareStatus(s.kind, pct, s.tail);
}

void StoandlClient::emitFirmwareStatus(const QString &phase, int percent, const QString &detail)
{
    // A downgrade on a dual-slot watch (`prf:<version>`): libpebble3 reboots the watch into recovery
    // with nothing flashed yet, and the daemon flashes the same .pbz once it reconnects there. So the
    // disconnect that follows is the reboot into PRF, not the end of the flash: the first prf restarts
    // the activity tracking and the timeout (the CLI's pollFirmwareStatus does the same), and arms the
    // poll even when the downgrade was started elsewhere (CLI) and only reached us as a signal.
    if (phase == QStringLiteral("prf")) {
        if (!m_fwViaRecovery) {
            m_fwViaRecovery = true;
            m_fwPrfVersion = detail;
            m_fwSeenActivity = false;
            m_fwElapsedMs = 0;
            if (!m_fwTimer->isActive())
                m_fwTimer->start();
            opPollsChanged();
        }
        Q_EMIT firmwareStatus(QStringLiteral("prf"), -1, m_fwPrfVersion);
        return;
    }

    // Track activity so a `notready` (link dropping on reboot) counts as success only *after*
    // we've seen real progress — same rule whether it arrived via the poll or the signal.
    if (phase == QStringLiteral("downloading") || phase == QStringLiteral("waiting")
        || phase == QStringLiteral("inprogress")) {
        m_fwSeenActivity = true;
        // Arm the op-poll watchdog even when the flash was kicked off from the *watch's own* update
        // notification (so the GUI never called startFirmwarePoll()). The poll is the authoritative
        // reboot/disconnect watchdog: FirmwareStatus returns `notready:` once the watch reboots and the
        // BLE link drops, which resolves to success below. Without this a watch-triggered flash rides the
        // FirmwareProgress signal alone, and the terminal `reboot:`/`notready:` frame is racy — libpebble3
        // itself notes WaitingForReboot "won't be in this state for long … we'll be disconnected very
        // soon" — so a lost terminal would leave the banner stuck on "Flashing…" forever. (Don't reset
        // m_fwSeenActivity here the way startFirmwarePoll() does — we've just set it true.)
        if (!m_fwTimer->isActive()) {
            m_fwElapsedMs = 0;
            m_fwTimer->start();
            opPollsChanged();
        }
    }

    // Between the reboot into recovery and the flash starting there, the watch is off the air
    // (`notready`) and then back in PRF but not yet flashing (`idle`): still the downgrade, so keep
    // reporting it rather than "waiting for the watch" or, worse, no flash at all.
    if (m_fwViaRecovery && !m_fwSeenActivity
        && (phase == QStringLiteral("idle") || phase == QStringLiteral("notready"))) {
        Q_EMIT firmwareStatus(QStringLiteral("prf"), -1, m_fwPrfVersion);
        return;
    }

    // Success = a `reboot` OR a `notready` seen after activity (the watch reboots → link drops).
    if (phase == QStringLiteral("reboot")
        || (phase == QStringLiteral("notready") && m_fwSeenActivity)) {
        endFirmwareOp();
        Q_EMIT firmwareStatus(QStringLiteral("success"), 100, QStringLiteral("Watch is rebooting"));
        return;
    }
    if (phase == QStringLiteral("failed")) {
        endFirmwareOp();
        Q_EMIT firmwareStatus(QStringLiteral("failed"), -1, detail);
        return;
    }
    // An idle/(pre-activity) notready poke when nothing's in flight: don't flicker the UI.
    // (Matches the poll, which only runs while m_fwTimer is active.)
    if ((phase == QStringLiteral("idle") || phase == QStringLiteral("notready"))
        && !m_fwTimer->isActive() && !m_fwSeenActivity)
        return;
    Q_EMIT firmwareStatus(phase, percent, detail); // idle / downloading / waiting / inprogress / pre-activity notready
}

// --- typed wrappers: System / language packs -------------------------------

namespace {
QVariant languageRows(const QVariantList &records)
{
    // Record: id \t isoLocal \t displayName \t installed(yes|no) \t source(rebble|github)
    QVariantList rows;
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
} // namespace

QVariantList StoandlClient::listLanguages()
{
    return read(QStringLiteral("listLanguages")).toList();
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
    opPollsChanged();
}

void StoandlClient::stopLanguagePoll() { m_langTimer->stop(); opPollsChanged(); }

void StoandlClient::languagePollOnce()
{
    m_langElapsedMs += LANG_INTERVAL_MS;
    if (m_langElapsedMs > LANG_TIMEOUT_MS) {
        stopLanguagePoll();
        Q_EMIT languageStatus(QStringLiteral("timeout"), -1, QStringLiteral("Install timed out"));
        return;
    }
    const Status s = callStatus(QStringLiteral("LanguageStatus"));
    // Skip one stale sticky terminal on the first poll (previous install's value). This is a
    // poll-only guard: the LanguageStatus method can snapshot the *prior* install's terminal,
    // whereas the LanguageProgress signal is always live, so the signal path must never drop one.
    if (m_langFirstPoll) {
        m_langFirstPoll = false;
        if (s.kind == QStringLiteral("done") || s.kind == QStringLiteral("idle")
            || s.kind == QStringLiteral("failed"))
            return;
    }
    const int pct = (s.kind == QStringLiteral("installing")) ? parsePercent(s.tail) : -1;
    emitLanguageStatus(s.kind, pct, s.tail);
}

void StoandlClient::emitLanguageStatus(const QString &phase, int percent, const QString &detail)
{
    // Track activity so a `notready` (link dropping mid-install) counts as a disconnect only
    // *after* real progress — same rule whether it arrived via the poll or the signal.
    if (phase == QStringLiteral("downloading") || phase == QStringLiteral("installing"))
        m_langSeenActivity = true;

    if (phase == QStringLiteral("done")) {
        stopLanguagePoll();
        Q_EMIT languageStatus(QStringLiteral("success"), 100, detail);
        return;
    }
    if (phase == QStringLiteral("failed")) {
        stopLanguagePoll();
        Q_EMIT languageStatus(QStringLiteral("failed"), -1, detail);
        return;
    }
    if (phase == QStringLiteral("notready") && m_langSeenActivity) {
        stopLanguagePoll();
        Q_EMIT languageStatus(QStringLiteral("disconnected"), -1, QStringLiteral("Watch disconnected"));
        return;
    }
    Q_EMIT languageStatus(phase, percent, detail); // idle / downloading / installing / pre-activity notready
}

// --- typed wrappers: System / diagnostics ----------------------------------

// An empty path lets the daemon pick a new file (it may run outside this GUI's Flatpak, whose /tmp differs).
QVariantMap StoandlClient::takeScreenshot()
{
    return startTask(QStringLiteral("screenshot"), QStringLiteral("TakeScreenshot"), {QString()});
}

QVariantMap StoandlClient::gatherLogs()
{
    return startTask(QStringLiteral("logs"), QStringLiteral("GatherLogs"), {QString()});
}

void StoandlClient::openFile(const QString &path)
{
    QDesktopServices::openUrl(QUrl::fromLocalFile(path));
}

void StoandlClient::openFolderOf(const QString &path)
{
    QDesktopServices::openUrl(QUrl::fromLocalFile(QFileInfo(path).absolutePath()));
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

namespace {
QVariant watchDetailsMap(const Status &s)
{
    // WatchDetails() -> ok:name\tcode\tmodel\tplatform\ttransport\tfirmware\tserial\tbattery\tlastSync
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
} // namespace

QVariantMap StoandlClient::watchDetails()
{
    return read(QStringLiteral("watchDetails")).toMap();
}

QVariantMap StoandlClient::setWatchNickname(const QString &name, const QString &nickname)
{
    return statusMap(callStatus(QStringLiteral("SetWatchNickname"), {name, nickname}));
}

namespace {
QVariant musicStatusMap(const Status &s)
{
    // MusicStatus() -> ok:<playing|paused>\t<player>\t<track>
    QVariantMap m;
    m[QStringLiteral("kind")] = s.kind;
    m[QStringLiteral("ok")]   = s.ok();
    if (s.kind == QStringLiteral("ok")) {
        m[QStringLiteral("playing")] = (s.fields.value(0) == QStringLiteral("playing"));
        m[QStringLiteral("player")]  = s.fields.value(1);
        m[QStringLiteral("track")]   = s.fields.value(2);
    }
    return m;
}
} // namespace

QVariantMap StoandlClient::musicStatus()
{
    return read(QStringLiteral("musicStatus")).toMap();
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

namespace {
QVariant devConnectionMap(const Status &s)
{
    QVariantMap m = statusMap(s);
    // ok:active / ok:inactive / notready:
    m[QStringLiteral("active")] = (s.kind == QStringLiteral("ok") && s.tail == QStringLiteral("active"));
    return m;
}
} // namespace

QVariantMap StoandlClient::devConnectionStatus()
{
    return read(QStringLiteral("devConnectionStatus")).toMap();
}

QVariantMap StoandlClient::getCoreDump()
{
    return startTask(QStringLiteral("coredump"), QStringLiteral("GetCoreDump"), {QString()});
}

// --- watch tasks -------------------------------------------------------------

namespace {
// A task's TaskStatus result as taskFinished() reports it: the status map, plus the file it wrote.
QVariantMap taskResultMap(const QString &kind, const Status &s)
{
    QVariantMap m = statusMap(s);
    if (s.ok() && kind != QLatin1String("sideload"))
        m[QStringLiteral("path")] = s.fields.value(0);
    if (s.ok() && kind == QLatin1String("screenshot")) {
        m[QStringLiteral("width")]  = s.fields.value(1).toInt();
        m[QStringLiteral("height")] = s.fields.value(2).toInt();
    }
    return m;
}
} // namespace

QVariantMap StoandlClient::startTask(const QString &kind, const QString &method, const QVariantList &args)
{
    const Status s = callStatus(method, args);
    if (s.ok() && s.tail == QLatin1String("started")) {
        m_tasks.insert(kind, QString());   // TaskChanged's running:<what> names it
        m_taskAge[kind].start();
        if (!m_taskTimer->isActive())
            m_taskTimer->start();
        Q_EMIT tasksChanged();
    } else if (s.ok() || s.kind == QLatin1String("none")) {
        // A daemon from before the watch tasks did the work in the call and answered with the result.
        const QVariantMap result = taskResultMap(kind, s);
        QTimer::singleShot(0, this, [this, kind, result] { Q_EMIT taskFinished(kind, result); });
    }
    return statusMap(s);
}

void StoandlClient::onTaskChanged(const QString &kind, const QString &status)
{
    qCDebug(lcStoandl).noquote() << "signal TaskChanged:" << kind << status;
    taskStatusSeen(kind, status);
}

void StoandlClient::taskStatusSeen(const QString &kind, const QString &status)
{
    if (!m_tasks.contains(kind))   // one this GUI didn't start (the CLI's), or already reported
        return;
    const Status s = parseStatus(status);
    if (s.kind == QLatin1String("running")) {
        if (m_tasks.value(kind).toString() != s.tail) {
            m_tasks.insert(kind, s.tail);
            Q_EMIT tasksChanged();
        }
        return;
    }
    if (s.kind == QLatin1String("idle"))   // the daemon restarted under the task: it is gone
        return taskStatusSeen(kind, QStringLiteral("error:stoandl restarted before it finished"));
    m_tasks.remove(kind);
    m_taskAge.remove(kind);
    if (m_tasks.isEmpty())
        m_taskTimer->stop();
    Q_EMIT tasksChanged();
    if (s.kind == QLatin1String("error") || s.kind == QLatin1String("failed"))
        qCWarning(lcStoandl).noquote().nospace() << "task " << kind << " -> " << s.kind << ": " << s.tail;
    Q_EMIT taskFinished(kind, taskResultMap(kind, s));
}

void StoandlClient::pollTasks()
{
    for (const QString &kind : m_tasks.keys()) {
        if (m_taskAge.value(kind).hasExpired(TASK_TIMEOUT_MS)) {
            taskStatusSeen(kind, QStringLiteral("timeout:it took longer than ten minutes"));
            continue;
        }
        readAsync(QStringLiteral("taskStatus"), {kind}, nullptr, [this, kind](const QVariant &v) {
            const QVariantMap m = v.toMap();
            const QString tail = m.value(QStringLiteral("tail")).toString();
            taskStatusSeen(kind, m.value(QStringLiteral("kind")).toString() + QLatin1Char(':') + tail);
        });
    }
}

// --- Extensions: config (HOOK #7) ------------------------------------------

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
        // Optional: one line under the field, and longer text behind its (?) button.
        f[QStringLiteral("description")] = o.value(QStringLiteral("description")).toString();
        f[QStringLiteral("help")]   = o.value(QStringLiteral("help")).toString();
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

namespace {
QVariant syncStatusRows(const QVariantList &records)
{
    // Record: service \t enabled \t available \t lastSync \t key (the stoandl.conf key SetSyncEnabled sets;
    // appended, so empty from an older daemon)
    QVariantList rows;
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        QVariantMap m;
        m[QStringLiteral("service")]   = f.value(0);
        m[QStringLiteral("enabled")]   = (f.value(1) == QStringLiteral("enabled"));
        m[QStringLiteral("available")] = (f.value(2) == QStringLiteral("available"));
        m[QStringLiteral("lastSync")]  = f.value(3);
        m[QStringLiteral("key")]       = f.value(4);
        rows.append(m);
    }
    return rows;
}
} // namespace

QVariantList StoandlClient::getSyncStatus()
{
    return read(QStringLiteral("getSyncStatus")).toList();
}

// --- Watch settings: prefs -------------------------------------------------

namespace {
QVariant watchPrefRows(const QVariantList &records)
{
    // Record: id \t type \t current \t default \t allowed \t flags \t name \t description \t section
    //         \t help \t requires
    // Columns 8-10 were appended: an older daemon leaves them empty, and its prefs land in "Other".
    //
    // type ∈ {bool, number, enum, quicklaunch, color, schedule} (the daemon's
    // WatchPrefsControl.typeName()). `allowed` is built by WatchPrefsControl.allowed() and is
    // **pipe-separated** for the option types — enum ("Standard - Low|Standard - High|…"),
    // quicklaunch ("off|Quiet Time|…|<app name or uuid>": the system actions sit between), color ("RRGGBB|<preset>|…") — and a "min..max[ unit]"
    // range for number, "true|false" for bool, the literal "HH:MM-HH:MM" for schedule (whose
    // current/default are a 24 h window such as "22:00-07:00"; an end before the start is overnight).
    // The QML renders one delegate per type, so split on '|' (NOT ','), and pre-derive the number
    // range + unit and the leading-int current value (a "3000 ms" current is not a plain int).
    QVariantList rows;
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        const QString type = f.value(1);
        const QString cur  = f.value(2);
        const QString allowedRaw = f.value(4);
        const QStringList flags = f.value(5).isEmpty() ? QStringList()
                                                       : f.value(5).split(QLatin1Char(','));
        QVariantMap m;
        m[QStringLiteral("id")]          = f.value(0);
        m[QStringLiteral("type")]        = type;
        m[QStringLiteral("current")]     = cur;
        m[QStringLiteral("currentBool")] = (cur == QStringLiteral("true"));
        m[QStringLiteral("currentInt")]  = parsePercent(cur);   // leading digits ("3000 ms" → 3000), -1 if none
        m[QStringLiteral("default")]     = f.value(3);
        // Pipe-split (the daemon joins option/range lists with '|'); empty → no options.
        m[QStringLiteral("allowed")]     = allowedRaw.isEmpty() ? QStringList()
                                                                : allowedRaw.split(QLatin1Char('|'));
        m[QStringLiteral("flags")]       = flags;
        m[QStringLiteral("debug")]       = flags.contains(QStringLiteral("debug"));
        m[QStringLiteral("name")]        = f.value(6);
        m[QStringLiteral("description")] = f.value(7);
        m[QStringLiteral("section")]     = f.value(8).isEmpty() ? QStringLiteral("Other") : f.value(8);
        m[QStringLiteral("help")]        = f.value(9);
        m[QStringLiteral("requires")]    = parseRequires(f.value(10));
        // Number prefs: pre-derive {min, max, unit} from the "min..max[ unit]" allowed range so the
        // QML spinbox gets clean ints + a unit suffix (a slider over a raw string can't).
        if (type == QStringLiteral("number")) {
            int rangeMin = 0, rangeMax = 100;
            QString unit;
            const int dots = allowedRaw.indexOf(QStringLiteral(".."));
            if (dots >= 0) {
                rangeMin = parsePercent(allowedRaw.left(dots));
                const QString hi = allowedRaw.mid(dots + 2).trimmed();   // "10000 ms"
                rangeMax = parsePercent(hi);
                const int sp = hi.indexOf(QLatin1Char(' '));
                if (sp >= 0)
                    unit = hi.mid(sp + 1).trimmed();
            }
            // The notification timeout runs from 15 s to 10 min: shown in seconds, sent in ms. (The
            // backlight timeout stays in ms, whose sub-second values whole seconds would lose.)
            const int scale = (f.value(0) == QStringLiteral("notifWindowTimeout") && unit == QStringLiteral("ms")) ? 1000 : 1;
            if (scale > 1) {
                unit = QStringLiteral("s");
                rangeMin /= scale;
                rangeMax /= scale;
                const int cur = m.value(QStringLiteral("currentInt")).toInt();
                m[QStringLiteral("currentInt")] = cur < 0 ? cur : cur / scale;
                const int def = parsePercent(f.value(3));
                if (def >= 0)
                    m[QStringLiteral("default")] = QStringLiteral("%1 s").arg(def / scale);
            }
            m[QStringLiteral("min")]  = rangeMin < 0 ? 0 : rangeMin;
            m[QStringLiteral("max")]  = rangeMax < 0 ? 100 : rangeMax;
            m[QStringLiteral("unit")] = unit;
            m[QStringLiteral("scale")] = scale;
        }
        rows.append(m);
    }
    return rows;
}
} // namespace

QVariantList StoandlClient::listWatchPrefs()
{
    return read(QStringLiteral("listWatchPrefs")).toList();
}

QVariantMap StoandlClient::setWatchPref(const QString &id, const QString &value)
{
    return statusMap(callStatus(QStringLiteral("SetWatchPref"), {id, value}));
}

QVariantMap StoandlClient::resetWatchPrefs()
{
    return statusMap(callStatus(QStringLiteral("ResetWatchPrefs")));
}

QString StoandlClient::normalizeSchedule(const QString &raw) const
{
    // libpebble3's QuietTimeSchedule.parse(), which SetWatchPref applies: exactly one '-' between two
    // times, each (trimmed) exactly one ':' between an hour 0-23 and a minute 0-59, digits only (an
    // optional '+' is what Kotlin's toIntOrNull also takes). Returned zero-padded, as the daemon
    // stores it and lists it back.
    static const QRegularExpression number(QStringLiteral("^\\+?\\d+$"));
    const QStringList times = raw.split(QLatin1Char('-'));
    if (times.size() != 2)
        return {};
    QStringList out;
    for (const QString &t : times) {
        const QStringList hm = t.trimmed().split(QLatin1Char(':'));
        if (hm.size() != 2 || !number.match(hm.at(0)).hasMatch() || !number.match(hm.at(1)).hasMatch())
            return {};
        bool okH = false, okM = false;
        const int h = hm.at(0).toInt(&okH);
        const int m = hm.at(1).toInt(&okM);
        if (!okH || !okM || h > 23 || m > 59)
            return {};
        out << QStringLiteral("%1:%2").arg(h, 2, 10, QLatin1Char('0')).arg(m, 2, 10, QLatin1Char('0'));
    }
    return out.join(QLatin1Char('-'));
}

// --- Daemon config, schema-driven (HOOK #10) -------------------------------

namespace {
QVariant configSchemaRows(const QVariantList &records)
{
    // Record: key \t type \t label \t options(comma) \t desc \t group \t apply \t min \t max \t unit
    //         \t placeholder \t page \t help \t requires \t default \t egress
    // Columns 5+ were appended to the original 5-column contract, so an older daemon simply leaves them
    // empty — hence the defaults below rather than a hard read. type ∈ {toggle, combo, text, int, list,
    // secret}; apply ∈ {live, restart} ("restart" = the daemon only picks the value up when it starts).
    // page is the Settings page, group the section on it; a daemon without pages puts every key on one.
    // default is the value an empty stoandl.conf gives (GetConfig's spelling), egress the hosts the key
    // makes stoandl contact (a noun phrase that reads after "Contacts").
    QVariantList rows;
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        QVariantMap m;
        m[QStringLiteral("key")]     = f.value(0);
        m[QStringLiteral("type")]    = f.value(1);
        m[QStringLiteral("label")]   = f.value(2);
        m[QStringLiteral("options")] = f.value(3).isEmpty() ? QStringList()
                                                            : f.value(3).split(QLatin1Char(','));
        m[QStringLiteral("desc")]    = f.value(4);
        m[QStringLiteral("group")]   = f.value(5).isEmpty() ? QStringLiteral("Settings") : f.value(5);
        m[QStringLiteral("restart")] = f.value(6) == QLatin1String("restart");
        // A number field without bounds would give the spin box a 0..0 range, so fall back to a wide one.
        bool okMin = false, okMax = false;
        const int lo = f.value(7).toInt(&okMin);
        const int hi = f.value(8).toInt(&okMax);
        m[QStringLiteral("min")] = okMin ? lo : 0;
        m[QStringLiteral("max")] = okMax ? hi : 1000000;
        m[QStringLiteral("unit")] = f.value(9);
        m[QStringLiteral("placeholder")] = f.value(10);
        m[QStringLiteral("page")]     = f.value(11).isEmpty() ? QStringLiteral("Daemon configuration") : f.value(11);
        m[QStringLiteral("help")]     = f.value(12);
        m[QStringLiteral("requires")] = parseRequires(f.value(13));
        m[QStringLiteral("default")]  = f.value(14);
        m[QStringLiteral("egress")]   = f.value(15);
        rows.append(m);
    }
    return rows;
}
} // namespace

QVariantList StoandlClient::configSchema()
{
    return read(QStringLiteral("configSchema")).toList();
}

namespace {
QVariant configValues(const QVariantList &records)
{
    // Record: key \t value
    QVariantMap values;
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        values[f.value(0)] = f.value(1);
    }
    QVariantMap m;
    m[QStringLiteral("values")] = values;
    return m;
}
} // namespace

QVariantMap StoandlClient::restartDaemon()
{
    return statusMap(callStatus(QStringLiteral("Restart")));
}

QString StoandlClient::guiVersion()
{
    return QStringLiteral(STOANDL_GUI_VERSION);
}

QVariantMap StoandlClient::getConfig()
{
    return read(QStringLiteral("getConfig")).toMap();
}

QVariantMap StoandlClient::setConfig(const QString &key, const QString &value)
{
    const Status s = callStatus(QStringLiteral("SetConfig"), {key, value});
    // A key the daemon reads only at startup says so at the end of its ok: ("… (restart stoandl to apply)").
    if (s.ok() && s.tail.endsWith(QStringLiteral("(restart stoandl to apply)")) && !m_restartPending.contains(key)) {
        m_restartPending.append(key);
        Q_EMIT restartPendingChanged();
    }
    return statusMap(s);
}

// --- Debug: the hourly analytics heartbeat ---------------------------------

namespace {
// Readable header for a metric-name prefix (everything before the first '_' — the daemon's own
// naming, e.g. battery_soc_pct / ble_disconnect_*). Unlisted prefixes fall back to the capitalised
// prefix, so a firmware that adds a whole new subsystem still gets a sane group header.
QString hbGroupLabel(const QString &prefix)
{
    static const QHash<QString, QString> LABELS = {
        { QStringLiteral("accel"),        QStringLiteral("Accelerometer") },
        { QStringLiteral("app"),          QStringLiteral("Apps") },
        { QStringLiteral("backlight"),    QStringLiteral("Backlight") },
        { QStringLiteral("battery"),      QStringLiteral("Battery") },
        { QStringLiteral("ble"),          QStringLiteral("Bluetooth LE") },
        { QStringLiteral("button"),       QStringLiteral("Buttons") },
        { QStringLiteral("connectivity"), QStringLiteral("Connectivity") },
        { QStringLiteral("cpu"),          QStringLiteral("CPU") },
        { QStringLiteral("drv"),          QStringLiteral("Drivers") },
        { QStringLiteral("flash"),        QStringLiteral("Flash") },
        { QStringLiteral("fw"),           QStringLiteral("Firmware") },
        { QStringLiteral("gesture"),      QStringLiteral("Gestures") },
        { QStringLiteral("hrm"),          QStringLiteral("Heart rate") },
        { QStringLiteral("i2c"),          QStringLiteral("I²C") },
        { QStringLiteral("last"),         QStringLiteral("Last reboot") },
        { QStringLiteral("low"),          QStringLiteral("Low power") },
        { QStringLiteral("memory"),       QStringLiteral("Memory") },
        { QStringLiteral("notification"), QStringLiteral("Notifications") },
        { QStringLiteral("pfs"),          QStringLiteral("Filesystem") },
        { QStringLiteral("phone"),        QStringLiteral("Phone") },
        { QStringLiteral("ppog"),         QStringLiteral("PPoG") },
        { QStringLiteral("settings"),     QStringLiteral("Settings") },
        { QStringLiteral("sifli"),        QStringLiteral("SiFli") },
        { QStringLiteral("speaker"),      QStringLiteral("Speaker") },
        { QStringLiteral("stack"),        QStringLiteral("Stacks") },
        { QStringLiteral("stationary"),   QStringLiteral("Stationary mode") },
        { QStringLiteral("task"),         QStringLiteral("Tasks") },
        { QStringLiteral("touch"),        QStringLiteral("Touch") },
        { QStringLiteral("unexpected"),   QStringLiteral("Unexpected reboots") },
        { QStringLiteral("uptime"),       QStringLiteral("Uptime") },
        { QStringLiteral("utc"),          QStringLiteral("Time zone") },
        { QStringLiteral("vibrator"),     QStringLiteral("Vibration") },
        { QStringLiteral("watchface"),    QStringLiteral("Watchface") },
    };
    const auto it = LABELS.constFind(prefix);
    if (it != LABELS.constEnd())
        return it.value();
    if (prefix.isEmpty())
        return QStringLiteral("Other");
    QString s = prefix;
    s[0] = s.at(0).toUpper();
    return s;
}
} // namespace

namespace {
QVariant heartbeatInfoMap(const Status &s)
{
    // ok:<watchTs>\t<rx>\t<size>\t<version>\t<buildId>\t<fw>\t<known>\t<metricCount>
    //   watchTs / rx are epoch seconds (watchTs may be 0 when the record carries no time),
    //   buildId is the firmware's GNU build-id (hex — identifies the exact build, NOT a git SHA),
    //   known = 1 when stoandl has a verified layout for this (size, version).
    // unknown:<label>  = that watch has no captured heartbeat yet (label = the watch's name)
    // notready:<msg>   = battery capture (the heartbeat's carrier) is disabled daemon-side
    QVariantMap m = statusMap(s);
    m[QStringLiteral("unknown")] = (s.kind == QStringLiteral("unknown"));
    // For the non-ok kinds the tail is the watch label / message; keep it under one key.
    m[QStringLiteral("label")]   = s.ok() ? QString() : s.tail;
    if (s.ok()) {
        const QStringList f = s.fields;
        m[QStringLiteral("watchTs")]     = f.value(0).toLongLong();
        m[QStringLiteral("rx")]          = f.value(1).toLongLong();
        m[QStringLiteral("size")]        = f.value(2).toInt();
        m[QStringLiteral("version")]     = f.value(3).toInt();
        m[QStringLiteral("buildId")]     = f.value(4);
        m[QStringLiteral("fw")]          = f.value(5);
        m[QStringLiteral("known")]       = (f.value(6) == QStringLiteral("1"));
        m[QStringLiteral("metricCount")] = f.value(7).toInt();
    }
    return m;
}

QVariant heartbeatGroups(const QVariantList &records)
{
    // Record: name \t value \t text \t raw — `value` is already scale-divided (empty for the
    // string metrics), `text` is set only for the string metrics (fw_version, watchface_name,
    // watchface_uuid), `raw` is the undivided wire integer (empty for strings). The list is empty
    // when there is no heartbeat OR its layout is unverified: stoandl never shows guessed values.
    //
    // Grouped here (not in QML) by the prefix before the first '_', first-seen order for both the
    // groups and their rows — that keeps the daemon's record order, which is the firmware's own
    // declaration order.
    QVariantList groups;
    QHash<QString, int> indexOf;   // group key -> index into `groups`
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        const QString name = f.value(0);
        if (name.isEmpty())
            continue;
        const QString value = f.value(1);
        const QString text  = f.value(2);
        const QString raw   = f.value(3);

        QVariantMap metric;
        metric[QStringLiteral("name")]  = name;
        metric[QStringLiteral("value")] = value;
        metric[QStringLiteral("text")]  = text;
        metric[QStringLiteral("raw")]   = raw;
        // What the row shows: the string metrics carry `text`, everything else the scaled `value`.
        metric[QStringLiteral("display")] = !text.isEmpty()  ? text
                                          : !value.isEmpty() ? value
                                                             : QStringLiteral("—");
        // A scaled metric divides the wire integer; surface the raw one as the row's sub-label.
        metric[QStringLiteral("rawDiffers")] = (!raw.isEmpty() && raw != value);

        const int us = name.indexOf(QLatin1Char('_'));
        const QString key = us > 0 ? name.left(us) : name;
        int gi = indexOf.value(key, -1);
        if (gi < 0) {
            QVariantMap g;
            g[QStringLiteral("group")]   = key;
            g[QStringLiteral("label")]   = hbGroupLabel(key);
            g[QStringLiteral("metrics")] = QVariantList();
            gi = groups.size();
            indexOf.insert(key, gi);
            groups.append(g);
        }
        QVariantMap g = groups.at(gi).toMap();
        QVariantList ms = g.value(QStringLiteral("metrics")).toList();
        ms.append(metric);
        g[QStringLiteral("metrics")] = ms;
        groups[gi] = g;
    }
    return groups;
}
} // namespace

QVariantMap StoandlClient::heartbeatInfo(const QString &watch)
{
    return read(QStringLiteral("heartbeatInfo"), {watch}).toMap();
}

QVariantList StoandlClient::heartbeatMetrics(const QString &watch)
{
    return read(QStringLiteral("heartbeatMetrics"), {watch}).toList();
}

// --- Notifications ---------------------------------------------------------

namespace {
QVariant notifRows(const QVariantList &records)
{
    // Record: name \t muteLabel \t color \t icon \t vibe \t lastNotifiedEpochSeconds \t appNamePlacement \t images
    // (the app's notification.app_name override, small|subtitle|off; empty = follows the global setting;
    // images is `off` when the app's pictures are off, empty = follows notification.images).
    QVariantList rows;
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        const QString mute = f.value(1);
        // `muted-until <ISO instant>` is a temporary mute; the others name a standing state.
        const bool until = mute.startsWith(QLatin1String("muted-until "));
        const QDateTime ends = until ? QDateTime::fromString(mute.mid(12), Qt::ISODateWithMs) : QDateTime();
        QVariantMap m;
        m[QStringLiteral("name")]         = f.value(0);
        m[QStringLiteral("mute")]         = mute;
        m[QStringLiteral("muted")]        = (mute != QStringLiteral("never"));
        m[QStringLiteral("muteKind")]     = until ? QStringLiteral("until") : mute;
        m[QStringLiteral("mutedUntil")]   = ends.isValid() ? ends.toSecsSinceEpoch() : 0;
        m[QStringLiteral("color")]        = f.value(2);
        m[QStringLiteral("icon")]         = f.value(3);
        m[QStringLiteral("vibe")]         = f.value(4);
        m[QStringLiteral("lastNotified")] = f.value(5);
        m[QStringLiteral("appNamePlacement")] = f.value(6);
        m[QStringLiteral("imagesOff")]    = (f.value(7) == QStringLiteral("off"));
        rows.append(m);
    }
    return rows;
}
} // namespace

QVariantList StoandlClient::notifList()
{
    return read(QStringLiteral("notifList")).toList();
}

QVariantMap StoandlClient::notifSetMute(const QString &name, const QString &spec)
{
    return statusMap(callStatus(QStringLiteral("NotifSetMute"), {name, spec}));
}
QVariantMap StoandlClient::notifSetMuteAll(const QString &spec)
{
    const QVariantMap r = statusMap(callStatus(QStringLiteral("NotifSetMuteAll"), {spec}));
    refreshMuteAll();
    return r;
}

void StoandlClient::refreshMuteAll()
{
    if (!m_daemonUp)
        return setMutedUntil(0);
    readAsync(QStringLiteral("notifMuteAllStatus"), {}, nullptr, [this](const QVariant &v) {
        const QVariantMap m = v.toMap();
        // An older daemon (no such method) answers an error: nothing is muted that way there.
        if (m_daemonUp)
            setMutedUntil(m.value(QStringLiteral("until")).toLongLong());
    });
}

void StoandlClient::setMutedUntil(qint64 epochSeconds)
{
    const qint64 left = epochSeconds - QDateTime::currentSecsSinceEpoch();
    if (left <= 0)
        epochSeconds = 0;
    if (epochSeconds > 0)
        m_muteEndTimer->start(int(std::min<qint64>(left * 1000, std::numeric_limits<int>::max())));
    else
        m_muteEndTimer->stop();
    if (epochSeconds != m_mutedUntil) {
        m_mutedUntil = epochSeconds;
        Q_EMIT mutedUntilChanged();
    }
}
QVariantMap StoandlClient::notifSetStyle(const QString &name, const QString &color,
                                         const QString &icon, const QString &vibe)
{
    return statusMap(callStatus(QStringLiteral("NotifSetStyle"), {name, color, icon, vibe}));
}
namespace {
QVariant styleChoicesMap(const QVariantList &records)
{
    // Record: kind(vibe|icon) \t value \t label; a vibe adds \t ms,ms,… \t builtin|custom
    QVariantList vibes, icons;
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        QVariantMap o;
        o[QStringLiteral("value")] = f.value(1);
        o[QStringLiteral("text")]  = f.value(2);
        if (f.value(0) == QStringLiteral("vibe")) {
            o[QStringLiteral("pattern")] = f.value(3);
            o[QStringLiteral("custom")]  = (f.value(4) == QStringLiteral("custom"));
            vibes.append(o);
        }
        else if (f.value(0) == QStringLiteral("icon"))
            icons.append(o);
    }
    QVariantMap m;
    m[QStringLiteral("vibes")] = vibes;
    m[QStringLiteral("icons")] = icons;
    return m;
}
} // namespace

QVariantMap StoandlClient::notifStyleChoices()
{
    return read(QStringLiteral("notifStyleChoices")).toMap();
}
QVariantMap StoandlClient::notifVibeTest(const QString &spec)
{
    return statusMap(callStatus(QStringLiteral("NotifVibeTest"), {spec}));
}
QVariantMap StoandlClient::notifSetAppName(const QString &name, const QString &placement)
{
    return statusMap(callStatus(QStringLiteral("NotifSetAppName"), {name, placement}));
}
QVariantMap StoandlClient::notifSetImages(const QString &name, const QString &mode)
{
    return statusMap(callStatus(QStringLiteral("NotifSetImages"), {name, mode}));
}

namespace {
QVariant notifFilterRows(const QVariantList &records)
{
    // Record: pattern \t action(allow|block)
    QVariantList rows;
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        QVariantMap m;
        m[QStringLiteral("pattern")] = f.value(0);
        m[QStringLiteral("action")]  = f.value(1);
        rows.append(m);
    }
    return rows;
}
} // namespace

QVariantList StoandlClient::notifListFilters()
{
    return read(QStringLiteral("notifListFilters")).toList();
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

namespace {
QVariant healthSummaryMap(const Status &s)
{
    // GetHealthSummary(periodType, offset) -> 20 tab fields for the selected period (day/week/month).
    QVariantMap m;
    m[QStringLiteral("kind")] = s.kind;
    if (s.kind != QStringLiteral("ok")) {
        m[QStringLiteral("msg")] = s.tail;
        return m;
    }
    const QStringList f = s.fields;
    m[QStringLiteral("stepsTotal")]     = f.value(0).toInt();
    m[QStringLiteral("stepsAvgPerDay")] = f.value(1).toInt();
    m[QStringLiteral("stepsTypical")]   = f.value(2).toInt();
    m[QStringLiteral("distanceKm")]     = f.value(3);
    m[QStringLiteral("kcal")]           = f.value(4).toInt();
    m[QStringLiteral("activeMin")]      = f.value(5).toInt();
    m[QStringLiteral("sleepTotalMin")]  = f.value(6).toInt();
    m[QStringLiteral("sleepDeepMin")]   = f.value(7).toInt();
    m[QStringLiteral("sleepLightMin")]  = f.value(8).toInt();
    m[QStringLiteral("sleepTypicalMin")]= f.value(9).toInt();
    // Epoch seconds (0 = n/a for week/month, or no session); QML formats to a clock time.
    m[QStringLiteral("sleepBedtime")]   = f.value(10).toLongLong();
    m[QStringLiteral("sleepWakeup")]    = f.value(11).toLongLong();
    m[QStringLiteral("hrAvg")]          = f.value(12).toInt();
    m[QStringLiteral("hrResting")]      = f.value(13).toInt();
    m[QStringLiteral("hrCurrent")]      = f.value(14).toInt();
    m[QStringLiteral("hrMin")]          = f.value(15).toInt();
    m[QStringLiteral("hrMax")]          = f.value(16).toInt();
    m[QStringLiteral("hrAvailable")]    = (f.value(17) == QStringLiteral("yes"));
    m[QStringLiteral("daysWithData")]   = f.value(18).toInt();
    m[QStringLiteral("lastSync")]       = f.value(19);
    return m;
}
} // namespace

QVariantMap StoandlClient::healthSummary(const QString &periodType, int offset)
{
    return read(QStringLiteral("healthSummary"), {periodType, offset}).toMap();
}

namespace {
QVariant stepsBarRows(const QVariantList &records)
{
    // GetHealthSeries("steps", …) for week/month -> one bar per day: label \t steps \t typical.
    QVariantList rows;
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        const QString val = f.value(1);
        QVariantMap m;
        m[QStringLiteral("label")]    = f.value(0);
        m[QStringLiteral("value")]    = val.isEmpty() ? 0 : val.toInt();
        m[QStringLiteral("hasValue")] = !val.isEmpty();
        m[QStringLiteral("typical")]  = f.value(2).toInt();
        rows.append(m);
    }
    return rows;
}
} // namespace

QVariantList StoandlClient::stepsBars(const QString &periodType, int offset)
{
    return read(QStringLiteral("stepsBars"), {periodType, offset}).toList();
}

namespace {
QVariant sleepTimelineRows(const QVariantList &records)
{
    // Daily sleep: startFraction \t widthFraction \t isDeep(0|1) — fractions of an 18 h window
    // (6 PM → noon). Light intervals first, deep last (draw deep on top).
    QVariantList rows;
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        QVariantMap m;
        m[QStringLiteral("start")] = f.value(0).toDouble();
        m[QStringLiteral("width")] = f.value(1).toDouble();
        m[QStringLiteral("deep")]  = (f.value(2).toInt() != 0);
        rows.append(m);
    }
    return rows;
}
} // namespace

QVariantList StoandlClient::sleepTimeline(const QString &periodType, int offset)
{
    return read(QStringLiteral("sleepTimeline"), {periodType, offset}).toList();
}

namespace {
QVariant sleepBarRows(const QVariantList &records)
{
    // Week/month sleep: one bar per night: label \t totalMin \t deepMin.
    QVariantList rows;
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        const int total = f.value(1).toInt();
        QVariantMap m;
        m[QStringLiteral("label")]    = f.value(0);
        m[QStringLiteral("value")]    = total;      // total minutes (bar height)
        m[QStringLiteral("deep")]     = f.value(2).toInt();
        m[QStringLiteral("hasValue")] = (total > 0);
        rows.append(m);
    }
    return rows;
}
} // namespace

QVariantList StoandlClient::sleepBars(const QString &periodType, int offset)
{
    return read(QStringLiteral("sleepBars"), {periodType, offset}).toList();
}

namespace {
QVariant heartSampleRows(const QVariantList &records)
{
    // Daily HR: minute-level samples for the day: minuteOfDay \t bpm. The QML plots each at its true
    // time (x = minute/1440) and derives min/max/avg. Empty list = that day has no heart-rate data.
    QVariantList rows;
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        QVariantMap m;
        m[QStringLiteral("minute")] = f.value(0).toInt();
        m[QStringLiteral("bpm")]    = f.value(1).toInt();
        rows.append(m);
    }
    return rows;
}
} // namespace

QVariantList StoandlClient::heartSamples(const QString &periodType, int offset)
{
    return read(QStringLiteral("heartSamples"), {periodType, offset}).toList();
}

namespace {
QVariant heartBarRows(const QVariantList &records)
{
    // Week/month HR: one bar per day: label \t avgBpm (empty avg = no reading that day).
    QVariantList rows;
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
} // namespace

QVariantList StoandlClient::heartBars(const QString &periodType, int offset)
{
    return read(QStringLiteral("heartBars"), {periodType, offset}).toList();
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
    const quint64 seq = ++m_watchesSeq;
    if (!m_daemonUp) {
        if (!m_linkPause.isEmpty()) { m_linkPause.clear(); Q_EMIT linkPauseChanged(); }
        Q_EMIT watchesChanged({});
        return;
    }
    // The watch list with the BluetoothStatus and LinkPause polls folded into the same tick: three reads in
    // parallel, applied together once all are in, unless a newer refresh started meanwhile.
    struct Round { QVariantMap bt, pause; QVariantList rows; int pending = 3; };
    auto round = std::make_shared<Round>();
    auto apply = [this, round, seq] {
        if (--round->pending > 0 || seq != m_watchesSeq)
            return;
        // `ok:off` => off; anything else (incl. an older daemon that lacks the method) => assume on, so
        // we never flash a false "Bluetooth is off" state.
        const bool on = !(round->bt.value(QStringLiteral("ok")).toBool()
                          && round->bt.value(QStringLiteral("tail")).toString() == QLatin1String("off"));
        if (on != m_bluetoothOn) { m_bluetoothOn = on; Q_EMIT bluetoothOnChanged(); }
        const QString pause = round->pause.value(QStringLiteral("ok")).toBool()
            ? round->pause.value(QStringLiteral("tail")).toString() : QString();
        if (pause != m_linkPause) { m_linkPause = pause; Q_EMIT linkPauseChanged(); }
        Q_EMIT watchesChanged(round->rows);
    };
    readAsync(QStringLiteral("bluetoothStatus"), {}, nullptr, [round, apply](const QVariant &v) { round->bt = v.toMap(); apply(); });
    readAsync(QStringLiteral("linkPause"), {}, nullptr, [round, apply](const QVariant &v) { round->pause = v.toMap(); apply(); });
    readAsync(QStringLiteral("listWatches"), {}, nullptr, [round, apply](const QVariant &v) { round->rows = v.toList(); apply(); });
}

// --- polling: pair ---------------------------------------------------------

void StoandlClient::startPairPoll()
{
    m_pairElapsedMs = 0;
    if (!m_pairTimer->isActive())
        m_pairTimer->start();
    opPollsChanged();
}

void StoandlClient::stopPairPoll()
{
    m_pairTimer->stop();
    opPollsChanged();
}

QString StoandlClient::busyOp() const
{
    return m_pairTimer->isActive() ? QStringLiteral("pairing")
         : m_fwTimer->isActive() ? QStringLiteral("firmware")
         : m_langTimer->isActive() ? QStringLiteral("language")
         : QString();
}

void StoandlClient::opPollsChanged()
{
    const QString op = busyOp();
    if (op != m_lastBusyOp) {
        m_lastBusyOp = op;
        Q_EMIT busyOpChanged();
    }
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
    // Terminal states per the daemon's dbus-interface.md: ok / error / timeout.
    if (s.kind == QStringLiteral("ok") || s.kind == QStringLiteral("error")
        || s.kind == QStringLiteral("timeout"))
        stopPairPoll();
}

// --- daemon lifecycle ------------------------------------------------------

void StoandlClient::recheckDaemon()
{
    const auto owned = [this](const char *name) {
        QDBusMessage m = QDBusMessage::createMethodCall(DBUS_SERVICE, DBUS_PATH, DBUS_IFACE,
                                                        QStringLiteral("NameHasOwner"));
        m.setArguments({ QString::fromLatin1(name) });
        const QDBusMessage r = m_bus.call(m, QDBus::Block, NAME_TIMEOUT_MS);
        return r.type() != QDBusMessage::ErrorMessage && r.arguments().value(0).toBool();
    };
    setInstanceUp(owned(INSTANCE));
    setDaemonUp(owned(SERVICE));
    probeService();
}

void StoandlClient::setDaemonUp(bool up)
{
    if (up == m_daemonUp)
        return;
    m_daemonUp = up;
    m_fwForceUnsupported = false;   // a restarted daemon may be a newer one
    dropCache();                    // … with other keys, other installed models or vibrations
    if (!m_readErrors.isEmpty()) {  // failures of the daemon before say nothing about this one
        m_readErrors.clear();
        Q_EMIT readErrorsChanged();
    }
    if (!m_restartPending.isEmpty()) {   // a daemon that went or came read stoandl.conf anew
        m_restartPending.clear();
        Q_EMIT restartPendingChanged();
    }
    if (up) {
        refreshForwarding();
        refreshMuteAll();
        callAsync(methodCall(QStringLiteral("Version"), {}), nullptr, [this](const QDBusMessage &reply) {
            const QString v = reply.type() == QDBusMessage::ErrorMessage || !m_daemonUp
                ? QString() : reply.arguments().value(0).toString();
            if (v != m_daemonVersion) {
                m_daemonVersion = v;
                Q_EMIT daemonVersionChanged();
            }
        });
    } else {
        setMutedUntil(0);
        if (!m_daemonVersion.isEmpty()) {
            m_daemonVersion.clear();
            Q_EMIT daemonVersionChanged();
        }
    }
    if (!up && !m_forwarding) {
        m_forwarding = true;        // unknown again: no banner while the daemon is away
        Q_EMIT forwardingChanged();
    }
    // A daemon that went away (or a new one) owes us a fresh firmware answer.
    if (m_fwHaveInfo || !m_fwInfo.isEmpty() || m_fwCheckInFlight)
        clearFirmwareInfo(true);
    if (!up)
        probeService();
    Q_EMIT daemonUpChanged();
    Q_EMIT daemonStateChanged();
}

void StoandlClient::dropCache(const QString &name)
{
    if (name.isEmpty())
        m_cache.clear();
    else
        m_cache.remove(name);
    ++m_cacheGeneration;
}

void StoandlClient::refreshForwarding()
{
    callAsync(methodCall(QStringLiteral("GetConfig"), {}), nullptr, [this](const QDBusMessage &reply) {
        if (reply.type() == QDBusMessage::ErrorMessage || !m_daemonUp)
            return;
        const QVariantMap values = configValues(recordsFromReply(QStringLiteral("GetConfig"), reply))
                                       .toMap().value(QStringLiteral("values")).toMap();
        const QVariant v = values.value(QStringLiteral("notification.forward"));
        const bool on = !v.isValid() || v.toString() != QStringLiteral("false");
        if (on != m_forwarding) {
            m_forwarding = on;
            Q_EMIT forwardingChanged();
        }
    });
}

void StoandlClient::onConfigChanged(const QString &key)
{
    qCDebug(lcStoandl).noquote() << "signal ConfigChanged:" << key;
    dropCache(QStringLiteral("configSchema"));
    if (key == QStringLiteral("notification.forward"))
        refreshForwarding();
    Q_EMIT configChanged(key);
}

void StoandlClient::onNameOwnerChanged(const QString &name, const QString &, const QString &newOwner)
{
    if (name == QLatin1String(INSTANCE))
        setInstanceUp(!newOwner.isEmpty());
    else if (name == QLatin1String(SERVICE))
        setDaemonUp(!newOwner.isEmpty());
}

void StoandlClient::setInstanceUp(bool up)
{
    if (up == m_instanceUp)
        return;
    m_instanceUp = up;
    if (!up)
        probeService();
    Q_EMIT daemonStateChanged();
}

namespace {
bool inFlatpak() { return QFile::exists(QStringLiteral("/.flatpak-info")); }
} // namespace

QString StoandlClient::daemonState() const
{
    if (m_daemonUp)
        return QStringLiteral("up");
    if (m_instanceUp)
        return QStringLiteral("starting");
    if (inFlatpak())
        return QStringLiteral("flatpak");
    return m_serviceState;
}

void StoandlClient::probeService()
{
    if (m_daemonUp || m_instanceUp || inFlatpak())
        return;
    runSystemctl({ QStringLiteral("show"), QStringLiteral("-p"), QStringLiteral("LoadState"),
                   QStringLiteral("-p"), QStringLiteral("ActiveState"), QStringLiteral("-p"), QStringLiteral("Result"),
                   QStringLiteral("stoandl") },
                 [this](bool ok, const QString &message, const QString &out) {
        QString state = QStringLiteral("stopped");
        if (message.startsWith(QLatin1String("could not run systemctl"))) {
            state = QStringLiteral("nosystemd");
        } else if (ok) {
            QHash<QString, QString> props;
            for (const QString &line : out.split(QLatin1Char('\n'), Qt::SkipEmptyParts))
                props.insert(line.section(QLatin1Char('='), 0, 0), line.section(QLatin1Char('='), 1));
            if (props.value(QStringLiteral("LoadState")) == QLatin1String("not-found"))
                state = QStringLiteral("notinstalled");
            else if (props.value(QStringLiteral("Result")) == QLatin1String("start-limit-hit"))
                state = QStringLiteral("startlimit");
            else if (props.value(QStringLiteral("ActiveState")) == QLatin1String("failed"))
                state = QStringLiteral("failed");
        }
        if (state != m_serviceState) {
            m_serviceState = state;
            Q_EMIT daemonStateChanged();
        }
    });
}

// --- reactive signals (de.yoxcu.stoandl.Control) ---------------------------
// Each reuses the existing refresh/emit path so the QML side needs no change.

void StoandlClient::onWatchesChanged()
{
    qCDebug(lcStoandl) << "signal WatchesChanged → refreshWatches()";
    refreshWatches();   // re-fetches ListWatches + BluetoothStatus, emits watchesChanged/bluetoothOnChanged
}

void StoandlClient::onLockerChanged()
{
    qCDebug(lcStoandl) << "signal LockerChanged → refreshApps()";
    m_icons.clear();    // an app's icon can come or go with the locker (pending answers still land)
    refreshApps();      // emits appsChanged (covers on-watch/CLI installs/removes + active-face change)
}

void StoandlClient::onCalendarsChanged()
{
    qCDebug(lcStoandl) << "signal CalendarsChanged → refreshCalendars()";
    refreshCalendars(); // emits calendarsChanged once the async sync added/dropped calendars
}

void StoandlClient::onFirmwareProgress(const QString &phase, int percent, const QString &detail)
{
    qCDebug(lcStoandl).noquote().nospace()
        << "signal FirmwareProgress: " << phase << " " << percent << "% " << detail;
    emitFirmwareStatus(phase, percent, detail);
}

void StoandlClient::onLanguageProgress(const QString &phase, int percent, const QString &detail)
{
    qCDebug(lcStoandl).noquote().nospace()
        << "signal LanguageProgress: " << phase << " " << percent << "% " << detail;
    emitLanguageStatus(phase, percent, detail);
}

void StoandlClient::onExtensionsChanged()
{
    qCDebug(lcStoandl) << "signal ExtensionsChanged → refreshExtensions()";
    refreshExtensions(); // emits extensionsChanged (covers CLI/other-client install/enable/disable/restart)
}

void StoandlClient::onExtensionStateChanged(const QString &name, const QString &state)
{
    qCDebug(lcStoandl).noquote().nospace()
        << "signal ExtensionStateChanged: " << name << " → " << state;
    // Record the override so extList() can surface a quarantined/exited extension that the polled
    // running|stopped flag can't reveal, then re-sync the list (the coarse part, like the poke).
    m_extState.insert(name, state);
    refreshExtensions(); // emits extensionsChanged with the merged runtimeState
}

void StoandlClient::runSystemctl(const QStringList &args,
                                 const std::function<void(bool ok, const QString &message, const QString &out)> &done)
{
    auto *p = new QProcess(this);
    // FailedToStart never reaches finished(), so each outcome reports exactly once.
    connect(p, &QProcess::errorOccurred, this, [p, done](QProcess::ProcessError e) {
        if (e != QProcess::FailedToStart)
            return;
        done(false, QStringLiteral("could not run systemctl (%1)").arg(p->errorString()), QString());
        p->deleteLater();
    });
    connect(p, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
            [p, done](int code, QProcess::ExitStatus st) {
        // systemctl explains a failure on stderr; its first line is the useful part ("Job for
        // stoandl.service failed because …" / "Unit stoandl.service not found.").
        QString msg = QString::fromUtf8(p->readAllStandardError()).trimmed().section(QLatin1Char('\n'), 0, 0);
        if (msg.isEmpty())
            msg = QStringLiteral("systemctl exited with code %1").arg(code);
        done(st == QProcess::NormalExit && code == 0, msg, QString::fromUtf8(p->readAllStandardOutput()));
        p->deleteLater();
    });
    p->start(QStringLiteral("systemctl"), QStringList{ QStringLiteral("--user") } + args);
}

void StoandlClient::startDaemon()
{
    // The daemon is NOT D-Bus-activated — start the systemd *user* service. Clear a failed unit
    // first: the unit allows StartLimitBurst=5 starts per 300 s, and once that trips a plain
    // `start` is refused until `reset-failed`, however long ago the crashes were. The reset's own
    // outcome doesn't matter (it fails harmlessly on a unit that isn't failed) — the start's does.
    runSystemctl({ QStringLiteral("reset-failed"), QStringLiteral("stoandl") }, [this](bool, const QString &, const QString &) {
        runSystemctl({ QStringLiteral("start"), QStringLiteral("stoandl") }, [this](bool ok, const QString &message, const QString &) {
            if (!ok) {
                qCWarning(lcStoandl).noquote() << "systemctl --user start stoandl failed:" << message;
                Q_EMIT daemonStartFailed(message);
                probeService();
                return;
            }
            // NameOwnerChanged should fire, but re-probe a couple of times as a fallback.
            QTimer::singleShot(1500, this, &StoandlClient::recheckDaemon);
            QTimer::singleShot(4000, this, &StoandlClient::recheckDaemon);
        });
    });
}

// --- Plugins and app permissions ---------------------------------------------

namespace {
QVariant pluginRows(const QVariantList &records)
{
    QVariantList rows;
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        QVariantMap m;
        m[QStringLiteral("uuid")]        = f.value(0);
        m[QStringLiteral("kind")]        = f.value(1);   // builtin | pbw | extension
        m[QStringLiteral("name")]        = f.value(2);
        m[QStringLiteral("description")] = f.value(3);
        m[QStringLiteral("sources")]     = f.value(4).split(QLatin1Char(','), Qt::SkipEmptyParts);
        m[QStringLiteral("actions")]     = f.value(5).split(QLatin1Char(','), Qt::SkipEmptyParts);
        rows.append(m);
    }
    return rows;
}
} // namespace

QVariantList StoandlClient::pluginList()
{
    return read(QStringLiteral("pluginList")).toList();
}

namespace {
QVariant permPendingRows(const QVariantList &records)
{
    QVariantList rows;
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        QVariantMap m;
        m[QStringLiteral("appUuid")]     = f.value(0);
        m[QStringLiteral("appName")]     = f.value(1);
        m[QStringLiteral("key")]         = f.value(2);
        m[QStringLiteral("label")]       = f.value(3);
        m[QStringLiteral("requestedAt")] = f.value(4).toLongLong();
        m[QStringLiteral("running")]     = f.value(5) != QStringLiteral("false"); // only running apps are prompted
        m[QStringLiteral("seen")]        = f.value(6) == QStringLiteral("true");  // put off with "later"
        rows.append(m);
    }
    return rows;
}
} // namespace

QVariantList StoandlClient::permPending()
{
    return read(QStringLiteral("permPending")).toList();
}

QVariantList StoandlClient::permList(const QString &app)
{
    QVariantList rows;
    for (const QVariant &v : list(QStringLiteral("PermList"), { app })) {
        const QStringList f = v.toStringList();
        QVariantMap m;
        m[QStringLiteral("key")]      = f.value(0);
        m[QStringLiteral("status")]   = f.value(1);   // granted | denied | auto | waiting | blocked
        m[QStringLiteral("kind")]     = f.value(2);   // read | write | exfiltrating
        m[QStringLiteral("label")]    = f.value(3);
        m[QStringLiteral("lastUsed")] = f.value(4).toLongLong();
        rows.append(m);
    }
    return rows;
}

QVariantMap StoandlClient::permSet(const QString &app, const QString &key, const QString &decision)
{
    return statusMap(callStatus(QStringLiteral("PermSet"), { app, key, decision }));
}

void StoandlClient::refreshPlugins()
{
    const quint64 seq = ++m_pluginsSeq;
    if (!m_daemonUp) {
        Q_EMIT pluginsChanged({});
        Q_EMIT permissionRequestsChanged({});
        return;
    }
    readAsync(QStringLiteral("pluginList"), {}, nullptr, [this, seq](const QVariant &rows) {
        if (seq == m_pluginsSeq)
            Q_EMIT pluginsChanged(rows.toList());
    });
    readAsync(QStringLiteral("permPending"), {}, nullptr, [this, seq](const QVariant &rows) {
        if (seq == m_pluginsSeq)
            Q_EMIT permissionRequestsChanged(rows.toList());
    });
}

void StoandlClient::onPluginsChanged()
{
    qCDebug(lcStoandl) << "signal PluginsChanged/PermissionRequestsChanged → refreshPlugins()";
    refreshPlugins();
}

// --- Voice -------------------------------------------------------------------

QVariantMap StoandlClient::voiceStatus() { return read(QStringLiteral("voiceStatus")).toMap(); }
QVariantMap StoandlClient::ttsStatus()   { return read(QStringLiteral("ttsStatus")).toMap(); }
QVariantMap StoandlClient::speak(const QString &text) { return statusMap(callStatus(QStringLiteral("Speak"), {text})); }
QVariantMap StoandlClient::stopSpeaking() { return statusMap(callStatus(QStringLiteral("StopSpeaking"))); }

namespace {
QVariant voiceModelRows(const QVariantList &records)
{
    QVariantList rows;
    for (const QVariant &v : records) {
        const QStringList f = v.toStringList();
        const QString state = f.value(4);   // installed | available | downloading:<pct> | failed:<msg>
        QVariantMap m;
        m[QStringLiteral("id")]          = f.value(0);
        m[QStringLiteral("name")]        = f.value(1);
        m[QStringLiteral("program")]     = f.value(2);
        m[QStringLiteral("sizeMb")]      = f.value(3).toInt();
        m[QStringLiteral("state")]       = state.section(QLatin1Char(':'), 0, 0);
        m[QStringLiteral("progress")]    = state.startsWith(QLatin1String("downloading:")) ? state.section(QLatin1Char(':'), 1).toInt() : 0;
        m[QStringLiteral("error")]       = state.startsWith(QLatin1String("failed:")) ? state.section(QLatin1Char(':'), 1) : QString();
        m[QStringLiteral("recommended")] = (f.value(5) == QStringLiteral("true"));
        m[QStringLiteral("engineOk")]    = (f.value(6) == QStringLiteral("true"));
        m[QStringLiteral("note")]        = f.value(7);
        // Appended column: stt (a speech model) or tts (a voice); an older daemon lists only models.
        m[QStringLiteral("kind")]        = f.value(8).isEmpty() ? QStringLiteral("stt") : f.value(8);
        rows.append(m);
    }
    return rows;
}
} // namespace

QVariantList StoandlClient::voiceModels()
{
    return read(QStringLiteral("voiceModels")).toList();
}

QVariantMap StoandlClient::voiceDownloadModel(const QString &id) { return statusMap(callStatus(QStringLiteral("VoiceDownloadModel"), {id})); }
QVariantMap StoandlClient::voiceCancelDownload()                 { return statusMap(callStatus(QStringLiteral("VoiceCancelDownload"))); }
QVariantMap StoandlClient::voiceRemoveModel(const QString &id)   { return statusMap(callStatus(QStringLiteral("VoiceRemoveModel"), {id})); }

int StoandlClient::incubatingObjects() const
{
    const QQmlEngine *engine = qmlEngine(this);
    const QQmlIncubationController *ic = engine ? engine->incubationController() : nullptr;
    return ic ? ic->incubatingObjectCount() : 0;
}

// --- typed reads, blocking or not --------------------------------------------

namespace {
// A typed read: its D-Bus method, an argument it puts before the caller's (GetHealthSeries' metric) or
// nullptr, the types of the caller's arguments (s string, i int32, x int64: numbers from QML arrive
// untyped, and BatteryHistory & co. take an 'x'), and the parser of its reply — the `as` records or
// the `s` status, whichever the method returns.
struct ReadSpec {
    const char *method;
    const char *lead;
    const char *sig;
    QVariant (*records)(const QVariantList &records);
    QVariant (*status)(const Status &s);
    int timeoutMs = CALL_TIMEOUT_MS;
    // Answered from StoandlClient's cache for the daemon running now (the read takes no arguments); see
    // dropCache()'s callers for when an answer goes stale.
    bool cached = false;
};

// A plain `s` reply, as call() returns it.
QVariant statusVariant(const Status &s) { return statusMap(s); }

// NotifMuteAllStatus() -> muted:<epoch seconds it ends> | none: → {kind, muted, until (epoch s, 0 = none)}.
QVariant muteAllMap(const Status &s)
{
    QVariantMap m = statusMap(s);
    const bool muted = s.kind == QLatin1String("muted");
    m[QStringLiteral("muted")] = muted;
    m[QStringLiteral("until")] = muted ? s.tail.toLongLong() : 0;
    return m;
}

// Every read fetch() can run, by the name of its Q_INVOKABLE (which runs it blocking through read()).
const ReadSpec *readSpec(const QString &name)
{
    static const QHash<QString, ReadSpec> READS = {
        { QStringLiteral("listApps"),         { "ListApps",          nullptr,  "",   appRows,          nullptr } },
        { QStringLiteral("appIcon"),          { "GetAppIcon",        nullptr,  "s",  nullptr,          appIconUrl } },
        { QStringLiteral("extList"),          { "ExtList",           nullptr,  "",   extRows,          nullptr } },
        { QStringLiteral("pluginList"),       { "PluginList",        nullptr,  "",   pluginRows,       nullptr } },
        { QStringLiteral("permPending"),      { "PermPending",       nullptr,  "",   permPendingRows,  nullptr } },
        { QStringLiteral("getSyncStatus"),    { "GetSyncStatus",     nullptr,  "",   syncStatusRows,   nullptr } },
        { QStringLiteral("musicStatus"),      { "MusicStatus",       nullptr,  "",   nullptr,          musicStatusMap } },
        { QStringLiteral("listWatchPrefs"),   { "ListWatchPrefs",    nullptr,  "",   watchPrefRows,    nullptr } },
        { QStringLiteral("configSchema"),     { "GetConfigSchema",   nullptr,  "",   configSchemaRows, nullptr, CALL_TIMEOUT_MS, true } },
        { QStringLiteral("getConfig"),        { "GetConfig",         nullptr,  "",   configValues,     nullptr } },
        { QStringLiteral("notifList"),        { "NotifList",         nullptr,  "",   notifRows,        nullptr } },
        { QStringLiteral("notifListFilters"), { "NotifListFilters",  nullptr,  "",   notifFilterRows,  nullptr } },
        { QStringLiteral("healthSummary"),    { "GetHealthSummary",  nullptr,  "si", nullptr,          healthSummaryMap } },
        { QStringLiteral("stepsBars"),        { "GetHealthSeries",   "steps",  "si", stepsBarRows,     nullptr } },
        { QStringLiteral("sleepTimeline"),    { "GetHealthSeries",   "sleep",  "si", sleepTimelineRows, nullptr } },
        { QStringLiteral("sleepBars"),        { "GetHealthSeries",   "sleep",  "si", sleepBarRows,     nullptr } },
        { QStringLiteral("heartSamples"),     { "GetHealthSeries",   "heart",  "si", heartSampleRows,  nullptr } },
        { QStringLiteral("heartBars"),        { "GetHealthSeries",   "heart",  "si", heartBarRows,     nullptr } },
        { QStringLiteral("batteryInsights"),  { "BatteryInsights",   nullptr,  "s",  nullptr,          batteryInsightsMap } },
        { QStringLiteral("batteryHistory"),   { "BatteryHistory",    nullptr,  "sx", nullptr,          batteryHistoryRows } },
        { QStringLiteral("batteryActivity"),  { "BatteryActivity",   nullptr,  "sx", nullptr,          batteryActivityRows } },
        { QStringLiteral("batteryPower"),     { "BatteryPower",      nullptr,  "sx", nullptr,          batteryPowerRows } },
        { QStringLiteral("taskStatus"),       { "TaskStatus",        nullptr,  "s",  nullptr,          statusVariant } },
        { QStringLiteral("listWatches"),      { "ListWatches",       nullptr,  "",   watchRows,        nullptr } },
        { QStringLiteral("bluetoothStatus"),  { "BluetoothStatus",   nullptr,  "",   nullptr,          statusVariant } },
        { QStringLiteral("linkPause"),        { "LinkPause",         nullptr,  "",   nullptr,          statusVariant } },
        { QStringLiteral("watchDetails"),     { "WatchDetails",      nullptr,  "",   nullptr,          watchDetailsMap } },
        { QStringLiteral("devConnectionStatus"), { "DevConnectionStatus", nullptr, "", nullptr,        devConnectionMap } },
        { QStringLiteral("listLanguages"),    { "ListLanguages",     nullptr,  "",   languageRows,     nullptr } },
        { QStringLiteral("listCalendars"),    { "ListCalendars",     nullptr,  "",   calendarRows,     nullptr } },
        { QStringLiteral("listCalendarSources"), { "ListCalendarSources", nullptr, "", calendarSourceRows, nullptr } },
        { QStringLiteral("healthProfile"),    { "GetHealthProfile",  nullptr,  "",   healthProfileMap, nullptr } },
        { QStringLiteral("heartbeatInfo"),    { "HeartbeatInfo",     nullptr,  "s",  nullptr,          heartbeatInfoMap } },
        { QStringLiteral("heartbeatMetrics"), { "HeartbeatMetrics",  nullptr,  "s",  heartbeatGroups,  nullptr } },
        { QStringLiteral("notifStyleChoices"), { "NotifStyleChoices", nullptr, "",   styleChoicesMap,  nullptr, CALL_TIMEOUT_MS, true } },
        { QStringLiteral("notifMuteAllStatus"), { "NotifMuteAllStatus", nullptr, "", nullptr,          muteAllMap } },
        { QStringLiteral("voiceModels"),      { "VoiceModels",       nullptr,  "",   voiceModelRows,   nullptr } },
        { QStringLiteral("voiceStatus"),      { "VoiceStatus",       nullptr,  "",   nullptr,          statusVariant } },
        { QStringLiteral("ttsStatus"),        { "TtsStatus",         nullptr,  "",   nullptr,          statusVariant } },
        // Actions that wait on the watch or the network: run() them.
        { QStringLiteral("syncWeather"),      { "SyncWeather",       nullptr,  "",   nullptr,  statusVariant, SLOW_CALL_TIMEOUT_MS } },
        { QStringLiteral("syncCalendar"),     { "SyncCalendar",      nullptr,  "",   nullptr,  statusVariant, SLOW_CALL_TIMEOUT_MS } },
        { QStringLiteral("syncHealth"),       { "SyncHealth",        nullptr,  "",   nullptr,  statusVariant, SLOW_CALL_TIMEOUT_MS } },
        { QStringLiteral("searchWeatherPlace"), { "SearchWeatherPlace", nullptr, "s", nullptr, placesMap,     SLOW_CALL_TIMEOUT_MS } },
        { QStringLiteral("updateFirmware"),   { "UpdateFirmware",    nullptr,  "",   nullptr,  statusVariant, SLOW_CALL_TIMEOUT_MS } },
        { QStringLiteral("launchApp"),        { "LaunchApp",         nullptr,  "s",  nullptr,  statusVariant, SLOW_CALL_TIMEOUT_MS } },
    };
    const auto it = READS.constFind(name);
    return it == READS.constEnd() ? nullptr : &it.value();
}

QVariantList readArgs(const ReadSpec &spec, const QVariantList &args)
{
    QVariantList out;
    if (spec.lead)
        out << QString::fromLatin1(spec.lead);
    for (int i = 0; spec.sig[i]; ++i) {
        const QVariant v = args.value(i);
        switch (spec.sig[i]) {
        case 'i': out << v.toInt(); break;
        case 'x': out << QVariant(v.toLongLong()); break;
        default:  out << v.toString(); break;
        }
    }
    return out;
}

QVariant parseRead(const ReadSpec &spec, const QDBusMessage &reply, bool starting)
{
    const QString method = QString::fromLatin1(spec.method);
    return spec.records ? spec.records(recordsFromReply(method, reply))
                        : spec.status(statusFromReply(method, reply, starting));
}

// A QML value as a list: arrays nested in a JS array can arrive wrapped as QJSValue.
QVariantList asList(const QVariant &v)
{
    if (v.metaType() == QMetaType::fromType<QJSValue>())
        return v.value<QJSValue>().toVariant().toList();
    return v.toList();
}
} // namespace

QVariant StoandlClient::read(const QString &name, const QVariantList &args)
{
    const ReadSpec *spec = readSpec(name);
    Q_ASSERT_X(spec, "StoandlClient::read", "a typed read missing from readSpec()");
    if (!spec)
        return {};
    if (spec->cached && m_cache.contains(name))
        return m_cache.value(name);
    const QDBusMessage reply = m_bus.call(methodCall(QString::fromLatin1(spec->method), readArgs(*spec, args)),
                                          QDBus::Block, spec->timeoutMs);
    noteReadResult(name, reply);
    const QVariant value = parseRead(*spec, reply, m_instanceUp);
    if (spec->cached && reply.type() != QDBusMessage::ErrorMessage)
        m_cache.insert(name, value);
    afterRead(name, value);
    return value;
}

void StoandlClient::afterRead(const QString &name, const QVariant &value)
{
    if (name == QLatin1String("updateFirmware") && value.toMap().value(QStringLiteral("ok")).toBool()) {
        startFirmwarePoll();
    } else if (name == QLatin1String("voiceModels")) {
        // The schema's model and voice dropdowns list what is installed: a download or removal changes them.
        QString installed = QStringLiteral("#");   // never null: null means "not read yet"
        for (const QVariant &row : value.toList()) {
            const QVariantMap m = row.toMap();
            if (m.value(QStringLiteral("state")).toString() == QLatin1String("installed"))
                installed += m.value(QStringLiteral("id")).toString() + QLatin1Char(',');
        }
        if (!m_installedModels.isNull() && installed != m_installedModels)
            dropCache(QStringLiteral("configSchema"));
        m_installedModels = installed;
    }
}

void StoandlClient::readAsync(const QString &name, const QVariantList &args, QObject *context,
                              const std::function<void(const QVariant &)> &done, bool user)
{
    const ReadSpec *spec = readSpec(name);
    if (!spec) {
        qCWarning(lcStoandl).noquote() << "no typed read named" << name;
        done(QVariant());
        return;
    }
    if (spec->cached && m_cache.contains(name)) {
        // Answered from the cache, still after this call returns, as a D-Bus answer would be.
        const QPointer<QObject> guard(context);
        const bool scoped = context != nullptr;
        const QVariant value = m_cache.value(name);
        QTimer::singleShot(0, this, [guard, scoped, done, value] {
            if (!scoped || guard)
                done(value);
        });
        return;
    }
    const quint64 generation = m_cacheGeneration;
    callAsync(methodCall(QString::fromLatin1(spec->method), readArgs(*spec, args)), context,
              [this, name, spec, done, generation](const QDBusMessage &reply) {
        noteReadResult(name, reply);
        const QVariant value = parseRead(*spec, reply, m_instanceUp);
        // Not an answer from before the cache was dropped (it may list the old keys or models).
        if (spec->cached && reply.type() != QDBusMessage::ErrorMessage && generation == m_cacheGeneration)
            m_cache.insert(name, value);
        afterRead(name, value);
        done(value);
    }, user, spec->timeoutMs);
}

void StoandlClient::noteReadResult(const QString &name, const QDBusMessage &reply)
{
    if (reply.type() == QDBusMessage::ErrorMessage) {
        const QString why = errorText(reply, m_instanceUp);
        if (m_readErrors.value(name).toString() != why) {
            m_readErrors.insert(name, why);
            Q_EMIT readErrorsChanged();
        }
    } else if (m_readErrors.remove(name) > 0) {
        Q_EMIT readErrorsChanged();
    }
}

void StoandlClient::callAsync(const QDBusMessage &message, QObject *context,
                              const std::function<void(const QDBusMessage &)> &done, bool user, int timeoutMs)
{
    const QPointer<QObject> guard(context);
    const bool scoped = context != nullptr;
    ++m_callsInFlight;
    if (user)
        ++m_userCallsInFlight;
    Q_EMIT callsInFlightChanged();
    auto *w = new QDBusPendingCallWatcher(m_bus.asyncCall(message, timeoutMs > 0 ? timeoutMs : CALL_TIMEOUT_MS), this);
    connect(w, &QDBusPendingCallWatcher::finished, this, [this, guard, scoped, done, user](QDBusPendingCallWatcher *self) {
        self->deleteLater();
        if (!scoped || guard)
            done(self->reply());
        // After `done`, so a follow-up call it starts keeps the count above zero.
        --m_callsInFlight;
        if (user)
            --m_userCallsInFlight;
        Q_EMIT callsInFlightChanged();
    });
}

void StoandlClient::callBack(const QJSValue &callback, const QVariant &value)
{
    QJSEngine *engine = qjsEngine(this);
    if (!engine || !callback.isCallable())
        return;
    QJSValue cb = callback;
    const QJSValue r = cb.call({ engine->toScriptValue(value) });
    if (r.isError())
        qCWarning(lcStoandl).noquote() << "callback failed:" << r.toString()
                                       << r.property(QStringLiteral("stack")).toString();
}

void StoandlClient::run(QObject *owner, const QVariantList &call, const QJSValue &callback)
{
    QVariantList args = call;
    const QString name = args.isEmpty() ? QString() : args.takeFirst().toString();
    readAsync(name, args, owner, [this, callback](const QVariant &value) { callBack(callback, value); }, true);
}

void StoandlClient::fetch(QObject *owner, const QVariantList &reads, const QJSValue &callback)
{
    // One read ["name", args...] or a list of them [["name", args...], ...].
    const bool single = reads.isEmpty() || reads.first().metaType() == QMetaType::fromType<QString>();
    const QVariantList batch = single ? QVariantList{ QVariant(reads) } : reads;

    const quint64 seq = ++m_fetchCounter;
    if (owner) {
        if (!m_fetchSeq.contains(owner))
            connect(owner, &QObject::destroyed, this, [this, owner] { m_fetchSeq.remove(owner); });
        m_fetchSeq.insert(owner, seq);
    }

    struct Batch { QVariantList values; int pending = 0; };
    auto b = std::make_shared<Batch>();
    b->values.resize(batch.size());
    b->pending = int(batch.size());
    const QPointer<QObject> guard(owner);
    auto deliver = [this, b, guard, owner, seq, single, callback]() {
        // The owner went away, or asked again since: this answer is stale.
        if (owner && (!guard || m_fetchSeq.value(owner) != seq))
            return;
        callBack(callback, single ? b->values.value(0) : QVariant(b->values));
    };
    for (qsizetype i = 0; i < batch.size(); ++i) {
        QVariantList read = asList(batch.at(i));
        const QString name = read.isEmpty() ? QString() : read.takeFirst().toString();
        readAsync(name, read, owner, [b, i, deliver](const QVariant &value) {
            b->values[i] = value;
            if (--b->pending == 0)
                deliver();
        }, true);
    }
}
