#pragma once

#include <QObject>
#include <QElapsedTimer>
#include <QQmlEngine>
#include <QDBusConnection>
#include <QVariantList>
#include <QVariantMap>
#include <QStringList>
#include <QHash>
#include <QSet>
#include <QUrl>
#include <QJSValue>
#include <QSize>

#include <functional>

class QTimer;

// The ONLY object that touches D-Bus. Registered as a QML singleton
// (`StoandlClient` in module org.stoandl.gui). Three jobs: call, parse, poll.
//
// Contract: de.yoxcu.stoandl.Control on the *session* bus, path /de/yoxcu/stoandl.
// The interface exposes reactive signals (WatchesChanged, FirmwareProgress, ConfigChanged, …) that
// augment polling; polling stays as the fallback (the daemon is not D-Bus-activated, so a
// late/reconnecting client can miss a signal). The QML never polls and never parses — all
// of that lives here. See the daemon's docs/dbus-interface.md.
class StoandlClient : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(bool daemonUp READ daemonUp NOTIFY daemonUpChanged)
    // Why the daemon isn't there, for the "not running" placeholder: `up`; `starting` (it holds its
    // instance name, not yet the public one); `flatpak` (this GUI runs in a Flatpak and can't ask the host's
    // systemd); `nosystemd` (no `systemctl` here, e.g. OpenRC); else what `systemctl --user show stoandl`
    // says: `notinstalled` (no unit), `startlimit` (it crashed too often and systemd gave up), `failed`
    // or `stopped`.
    Q_PROPERTY(QString daemonState READ daemonState NOTIFY daemonStateChanged)
    // Host Bluetooth on/usable (BluetoothStatus, polled on the 20 s watch tick). The daemon detects
    // adapter-off / rfkill / airplane-mode; the GUI shows a "Bluetooth is off" state when this is false.
    Q_PROPERTY(bool bluetoothOn READ bluetoothOn NOTIFY bluetoothOnChanged)
    // Why the watch link is held off (LinkPause, read with every watch refresh): "manual" (Disconnect),
    // "quiet_time" (power.quiet_time_link_off), both comma-separated, or "" (also for an older daemon).
    Q_PROPERTY(QString linkPause READ linkPause NOTIFY linkPauseChanged)
    // Headless verification harness (sandbox only): milliseconds per step when STOANDL_SMOKE_MS is
    // set, else 0. Main.qml steps through every tab, exercises the Settings sub-pages and quits, so
    // `QT_QPA_PLATFORM=offscreen tools/run-with-mock.sh` proves QML -> D-Bus -> mock -> render
    // end-to-end and self-terminates.
    Q_PROPERTY(int smokeMs READ smokeMs CONSTANT)
    // STOANDL_SMOKE_FLASH=1 (with STOANDL_SMOKE_MS): the Watch page's smoke hook starts a flash of a .pbz
    // that doesn't exist, so the GUI-started firmware path runs end to end against the mock, which walks
    // any path (MOCK_FW_DOWNGRADE=1|drop picks the walk). A real daemon refuses the missing file.
    Q_PROPERTY(bool smokeFlash READ smokeFlash CONSTANT)
    // STOANDL_SMOKE_SIZE=<w>x<h> (e.g. 360x740, a phone): the window size Main.qml starts the smoke walk at;
    // invalid when unset.
    Q_PROPERTY(QSize smokeSize READ smokeSize CONSTANT)
    // The last CheckFirmware result for the watches the Watch page last asked about (see
    // requestFirmwareCheck): {kind, tail, ok, notready, board, current, latest, asset,
    // updateAvailable, source, changelogUrl}, or {} before the first answer. Owned here, not by the
    // page, so a Watch page recreated by a tab switch shows it at once instead of checking again.
    Q_PROPERTY(QVariantMap firmwareInfo READ firmwareInfo NOTIFY firmwareInfoChanged)
    // A CheckFirmware call is in flight (the daemon may download a release list first: seconds).
    Q_PROPERTY(bool firmwareChecking READ firmwareChecking NOTIFY firmwareInfoChanged)
    // Asynchronous calls in flight (fetch(), run(), the refresh*() reloads, app icons; not the firmware
    // check). The smoke harness waits for 0 before it exercises a page whose loads are asynchronous.
    Q_PROPERTY(int callsInFlight READ callsInFlight NOTIFY callsInFlightChanged)
    // The part of callsInFlight someone is waiting for: fetch() and run(), not the background refreshes
    // and polls. Main.qml's thin progress bar follows it.
    Q_PROPERTY(int userCallsInFlight READ userCallsInFlight NOTIFY callsInFlightChanged)
    // The watch tasks this GUI started that are still running: kind (sideload | screenshot | logs |
    // coredump) → what the daemon says it does ("Installing x.pbw"). Each ends with taskFinished.
    Q_PROPERTY(QVariantMap tasks READ tasks NOTIFY tasksChanged)
    // notification.forward, the master switch for forwarding (read with GetConfig when the daemon comes
    // up and on every ConfigChanged for it). True until known, so no "forwarding is off" banner flashes
    // before the first answer; also true with a daemon that predates the key.
    Q_PROPERTY(bool forwarding READ forwarding NOTIFY forwardingChanged)
    // This GUI's version (git describe at build time, else the CMake project version), for About.
    Q_PROPERTY(QString guiVersion READ guiVersion CONSTANT)
    // stoandl.conf keys set here (setConfig) that the daemon only applies when it starts again, in the
    // order they were set. Cleared when the daemon goes or comes (its restart applied them).
    Q_PROPERTY(QStringList restartPending READ restartPending NOTIFY restartPendingChanged)
    // When the temporary mute of every app (NotifSetMuteAll) ends, epoch seconds; 0 while nothing is muted
    // that way. Read when the daemon comes up, after notifSetMuteAll() and on refreshMuteAll(); drops to 0
    // by itself when the time comes (the daemon sends no signal for it).
    Q_PROPERTY(qint64 mutedUntil READ mutedUntil NOTIFY mutedUntilChanged)
    // A long operation this GUI follows that the daemon won't restart under: "pairing" (a Pair/Repair
    // window), "firmware" (a flash) or "language" (a language pack install); "" when none runs.
    Q_PROPERTY(QString busyOp READ busyOp NOTIFY busyOpChanged)
    // The running daemon's Version(), read when it comes up; "" while it is down or before the answer.
    Q_PROPERTY(QString daemonVersion READ daemonVersion NOTIFY daemonVersionChanged)
    // Typed reads whose last D-Bus call failed: read name ("notifList", …) → why, in the words errorText()
    // gives it. A read that succeeds drops its entry. Lets a page say "couldn't read" rather than show an
    // empty list; a status read carries its failure in its own value ({kind: "error", tail: why}).
    Q_PROPERTY(QVariantMap readErrors READ readErrors NOTIFY readErrorsChanged)

public:
    explicit StoandlClient(QObject *parent = nullptr);

    bool daemonUp() const { return m_daemonUp; }
    QString daemonState() const;
    bool bluetoothOn() const { return m_bluetoothOn; }
    QString linkPause() const { return m_linkPause; }
    static int smokeMs() { return qEnvironmentVariableIntValue("STOANDL_SMOKE_MS"); }
    static bool smokeFlash() { return smokeMs() > 0 && qEnvironmentVariableIntValue("STOANDL_SMOKE_FLASH") == 1; }
    static QSize smokeSize()
    {
        const QStringList wh = qEnvironmentVariable("STOANDL_SMOKE_SIZE").split(QLatin1Char('x'));
        return wh.size() == 2 ? QSize(wh.at(0).toInt(), wh.at(1).toInt()) : QSize();
    }
    // Smoke harness: objects the QML engine is still creating asynchronously (the settings pages'
    // row Loaders). The smoke waits for 0 (and callsInFlight 0) before it exercises or destroys a page:
    // destroying rows mid-incubation can leave Qt's in-progress-creation count behind.
    Q_INVOKABLE int incubatingObjects() const;
    QVariantMap firmwareInfo() const { return m_fwInfo; }
    bool firmwareChecking() const { return m_fwCheckInFlight; }
    int callsInFlight() const { return m_callsInFlight; }
    int userCallsInFlight() const { return m_userCallsInFlight; }
    QVariantMap tasks() const { return m_tasks; }
    bool forwarding() const { return m_forwarding; }
    QStringList restartPending() const { return m_restartPending; }
    QString daemonVersion() const { return m_daemonVersion; }
    qint64 mutedUntil() const { return m_mutedUntil; }
    QString busyOp() const;
    QVariantMap readErrors() const { return m_readErrors; }
    static QString guiVersion();

    // Parsed status string: "kind:tail", tail tab-split into fields.
    struct Status {
        QString kind;
        QString tail;
        QStringList fields;
        bool ok() const { return kind == QStringLiteral("ok"); }
    };

    // --- generic (any method) ----------------------------------------------
    // s-returning call -> { kind, tail, fields[], ok, notready }
    Q_INVOKABLE QVariantMap call(const QString &method, const QVariantList &args = {});
    // as-returning call -> [ [f0, f1, ...], ... ] (one QStringList per record)
    Q_INVOKABLE QVariantList list(const QString &method, const QVariantList &args = {});
    // A typed read without blocking, for page loads: `reads` is one read, named like its Q_INVOKABLE
    // with its arguments after it (["healthSummary", "day", 0]), or a list of them ([["configSchema"],
    // ["getConfig"]]). The calls run in parallel; `callback` gets what the synchronous call returns (or
    // the values in order, for a list) once all of them are in. Scoped to `owner`: nothing is delivered
    // after it is destroyed, and a newer fetch for the same owner drops one still in flight (latest
    // wins). The reads available are the ones readSpec() in the .cpp lists.
    Q_INVOKABLE void fetch(QObject *owner, const QVariantList &reads, const QJSValue &callback);
    // An action without blocking, for the calls that can take seconds (a sync, a search, a launch, a
    // firmware update): `call` is ["name", args...] like one fetch() read, from the same readSpec() table,
    // and `callback` gets what the synchronous Q_INVOKABLE of that name returns. Unlike fetch(), every
    // run() is answered (nothing is dropped for a newer one), unless `owner` died first.
    Q_INVOKABLE void run(QObject *owner, const QVariantList &call, const QJSValue &callback);

    // --- typed wrappers: Watch screen --------------------------------------
    Q_INVOKABLE QVariantList listWatches();              // -> [{name,state,battery,transport,connected}]
    Q_INVOKABLE QVariantMap  battery();                  // Battery()  -> status map
    // Battery insights (rich): BatteryInsights(s) -> {kind,ok,name,level,charging,dischargePerHour,
    // hoursRemaining,chargeSessions,lastChargedEpoch,min24h,max24h,sampleCount,voltage,source}.
    Q_INVOKABLE QVariantMap  batteryInsights(const QString &watch = QString());
    // Battery %-over-time series: BatteryHistory(s,x) -> [{ts,level,source,voltage}] (oldest first).
    Q_INVOKABLE QVariantList batteryHistory(const QString &watch, qlonglong sinceEpoch);
    // Per-interval drop + notifications: BatteryActivity(s,x) -> [{ts,drop,notif,notifDnd}] (oldest first).
    Q_INVOKABLE QVariantList batteryActivity(const QString &watch, qlonglong sinceEpoch);
    // Battery-drain attribution (estimate): BatteryPower(s,x) -> [{category,estDrainPct,share}] (largest first).
    Q_INVOKABLE QVariantList batteryPower(const QString &watch, qlonglong sinceEpoch);
    Q_INVOKABLE QVariantMap  connectWatch(const QString &name); // Connect(s); "" resumes after Disconnect
    Q_INVOKABLE QVariantMap  disconnectWatch();          // Disconnect() — keep every watch off until Connect
    Q_INVOKABLE QVariantMap  pair();                     // Pair() then start the PairStatus poll
    Q_INVOKABLE QVariantMap  pairStatusNow();            // PairStatus() one-shot (poll uses this)
    Q_INVOKABLE QVariantMap  confirmPairing(bool accept);// ConfirmPairing(b) — answer a confirm:<code>
    Q_INVOKABLE QVariantMap  repair(const QString &name);// Repair(s) -> reopen pairing window
    Q_INVOKABLE QVariantMap  unpair(const QString &name);// Unpair(s); "" = forget all
    Q_INVOKABLE void         findWatch();                // FindWatch() (b) — async, may block daemon-side
    Q_INVOKABLE QVariantMap  watchInfoText();            // WatchInfoText() -> {kind, text}
    // Watch-details dialog (§4d). WatchDetails() -> structured identity (HOOK).
    Q_INVOKABLE QVariantMap  watchDetails();             // -> {kind,name,code,model,platform,transport,firmware,serial,battery,lastSync}
    Q_INVOKABLE QVariantMap  setWatchNickname(const QString &name, const QString &nickname); // HOOK #9
    Q_INVOKABLE QVariantMap  startDevConnection();       // StartDevConnection() -> {kind, port}
    Q_INVOKABLE QVariantMap  stopDevConnection();        // StopDevConnection()
    Q_INVOKABLE QVariantMap  devConnectionStatus();      // DevConnectionStatus() -> {kind, active}
    // The watch's last core dump, as a watch task (see takeScreenshot): taskFinished("coredump",
    // {kind ok|none|notready|error, path}).
    Q_INVOKABLE QVariantMap  getCoreDump();

    // --- typed wrappers: Apps & Faces screen (Milestone 2) -----------------
    Q_INVOKABLE QVariantList listApps();                 // -> [{uuid,type,order,title,developer,flags[],active,system,config,sideloaded,isFace}]
    // The app's menu-icon PNG as a local "file://" URL (co-located daemon), or "" when the daemon has
    // none (none:/notready:/error:) or the answer isn't in yet. Answers are cached per uuid until the
    // next LockerChanged; a miss asks GetAppIcon asynchronously and announces the answer through
    // appIconChanged. A "none" is trusted for a minute (the daemon can fetch a .pbw after the
    // LockerChanged that listed it). The QML falls back to a generic icon on "".
    Q_INVOKABLE QString      appIcon(const QString &uuid);
    Q_INVOKABLE QVariantMap  launchApp(const QString &id);   // LaunchApp(s)
    Q_INVOKABLE QVariantMap  removeApp(const QString &id);   // RemoveApp(s) (system refused daemon-side)
    Q_INVOKABLE QVariantMap  setAppOrder(const QString &id, int order);  // SetAppOrder(s,i)
    Q_INVOKABLE QVariantMap  restoreSystemAppOrder();                    // RestoreSystemAppOrder()
    // SideloadApp(absolute daemon-side path), a watch task: taskFinished("sideload", {kind, tail}).
    Q_INVOKABLE QVariantMap  sideloadApp(const QUrl &fileUrl);
    Q_INVOKABLE QVariantMap  openConfig(const QString &id);  // OpenConfig(s) -> open the daemon-served page via xdg-open
    Q_INVOKABLE void         refreshApps();              // async re-fetch → appsChanged (on show + after any mutation)

    // --- typed wrappers: Extensions (Apps screen, 3rd segment) -------------
    Q_INVOKABLE QVariantList extList();                  // -> [{name,installed,enabled,running,config,description,author,version,lastStderr}]
    Q_INVOKABLE QVariantMap  extEnable(const QString &name);   // ExtEnable(s)
    Q_INVOKABLE QVariantMap  extDisable(const QString &name);  // ExtDisable(s)
    Q_INVOKABLE QVariantMap  extRestart(const QString &name);  // ExtRestart(s)
    Q_INVOKABLE QVariantMap  extUninstall(const QString &name, bool keepConfig); // ExtUninstall(s,b)
    Q_INVOKABLE QVariantMap  extInstall(const QUrl &archiveUrl); // ExtInstall(absolute daemon-side path)
    Q_INVOKABLE void         refreshExtensions();        // async re-fetch → extensionsChanged (on show + after any mutation)

    // --- Plugins and app permissions ---
    Q_INVOKABLE QVariantList pluginList();               // PluginList() -> [{uuid,kind,name,description,sources[],actions[]}]
    Q_INVOKABLE QVariantList permPending();              // PermPending() -> [{appUuid,appName,key,label,requestedAt,running,seen}]
    Q_INVOKABLE QVariantList permList(const QString &app); // PermList(s) -> [{key,status,kind,label,lastUsed}]
    Q_INVOKABLE QVariantMap  permSet(const QString &app, const QString &key, const QString &decision); // PermSet(s,s,s): allow|deny|reset|later
    Q_INVOKABLE void         refreshPlugins();           // async re-fetch → pluginsChanged + permissionRequestsChanged

    // --- Voice (speech-to-text models, Settings → Voice) ---
    Q_INVOKABLE QVariantMap  voiceStatus();              // VoiceStatus() -> {kind: off|ready|unavailable, tail}
    // VoiceModels() -> [{id,name,program,sizeMb,state,progress,error,recommended,engineOk,note,kind}];
    // kind is stt (speech to text) or tts (a voice), "stt" from a daemon without the column. A change in
    // the installed set drops the cached config schema (its model and voice dropdowns list them).
    Q_INVOKABLE QVariantList voiceModels();
    Q_INVOKABLE QVariantMap  voiceDownloadModel(const QString &id); // VoiceDownloadModel(s): ok|installed|busy|notfound
    Q_INVOKABLE QVariantMap  voiceCancelDownload();      // VoiceCancelDownload()
    Q_INVOKABLE QVariantMap  voiceRemoveModel(const QString &id);   // VoiceRemoveModel(s)
    // Text to speech (Settings → Voice). TtsStatus() -> {kind: off|ready|unavailable, tail}; Speak(s) plays
    // the text on this computer (ok/off/unavailable/busy/error); StopSpeaking() stops it.
    Q_INVOKABLE QVariantMap  ttsStatus();
    Q_INVOKABLE QVariantMap  speak(const QString &text);
    Q_INVOKABLE QVariantMap  stopSpeaking();
    // HOOK #7 — extension config: a native form from the manifest's configSchema.
    Q_INVOKABLE QVariantList extConfigSchema(const QString &name); // ExtConfigSchema(s) -> [{key,type,label,secret,options[],description,help}]
    Q_INVOKABLE QVariantMap  extGetConfig(const QString &name);    // ExtGetConfig(s)   -> {key:value, ...}
    Q_INVOKABLE QVariantMap  extSetConfig(const QString &name, const QVariantMap &values); // ExtSetConfig(s, json)

    // --- typed wrappers: Sync services (Settings screen) -------------------
    Q_INVOKABLE QVariantMap  syncWeather();              // SyncWeather() ; error: if disabled in config
    Q_INVOKABLE QVariantMap  searchWeatherPlace(const QString &query); // SearchWeatherPlace(s) -> {kind,ok,tail,places:[{name,lat,lon,region,country}]}
    Q_INVOKABLE QVariantMap  addWeatherLocation(const QString &name, double lat, double lon); // AddWeatherLocation(s,d,d)
    Q_INVOKABLE QVariantMap  syncCalendar();             // SyncCalendar()
    Q_INVOKABLE QVariantMap  syncHealth();               // SyncHealth()
    Q_INVOKABLE QVariantMap  healthProfile();            // GetHealthProfile() -> {key: value, ..., _allowed: {key: [values]}}
    Q_INVOKABLE QVariantMap  setHealthProfile(const QString &key, const QString &value); // SetHealthProfile(s,s)
    Q_INVOKABLE QVariantList listCalendars();            // -> [{id,name,enabled,accountId}]
    Q_INVOKABLE QVariantMap  setCalendarEnabled(const QString &id, bool enabled); // SetCalendarEnabled(s,b)
    Q_INVOKABLE void         refreshCalendars();         // async re-fetch → calendarsChanged (latest wins)
    // Calendar *sources* (CalDAV accounts / iCal feeds / .ics paths) — the Calendars settings screen.
    Q_INVOKABLE QVariantList listCalendarSources();      // -> [{id,type,url,username,label,lastError,lastSync}] (no password)
    Q_INVOKABLE QVariantMap  addCalendarSource(const QString &type, const QString &url,
                                               const QString &username, const QString &password);
    Q_INVOKABLE QVariantMap  updateCalendarSource(const QString &id, const QString &url,
                                                  const QString &username, const QString &password);
    Q_INVOKABLE QVariantMap  removeCalendarSource(const QString &id);
    // HOOK #5 — per-service status (a master is switched through setConfig of its key, like any key).
    Q_INVOKABLE QVariantList getSyncStatus();            // -> [{service,enabled,available,lastSync,key}]
    Q_INVOKABLE QVariantMap  musicStatus();              // MusicStatus() -> {kind,ok,playing,player,track}

    // --- typed wrappers: Watch settings (Settings screen) ------------------
    // -> [{id,type,current,default,allowed[],flags[],name,description,section,help,requires[]}], plus
    // number prefs' {min,max,unit,scale}: notifWindowTimeout is shown in seconds (scale 1000, a value to
    // send is shown × scale), every other number as the daemon lists it (scale 1).
    Q_INVOKABLE QVariantList listWatchPrefs();
    Q_INVOKABLE QVariantMap  setWatchPref(const QString &id, const QString &value); // SetWatchPref(s,s)
    Q_INVOKABLE QVariantMap  resetWatchPrefs();          // ResetWatchPrefs() -> ok:<message> | notready:
    // A `schedule` pref value as the daemon would store it ("7:5-22:30" -> "07:05-22:30"), or ""
    // when SetWatchPref would reject it (libpebble3's QuietTimeSchedule.parse rules: H:MM or HH:MM
    // on both sides of one '-', hours 0-23, minutes 0-59). Lets the editor flag a bad value before
    // sending; the daemon's own error is still shown if it disagrees.
    Q_INVOKABLE QString      normalizeSchedule(const QString &raw) const;

    // --- typed wrappers: Daemon config (Settings -> Advanced) — HOOK #10 ---
    // GetConfigSchema() -> [{key,type,label,options[],desc,group,restart,min,max,unit,placeholder,page,help,
    // requires[{key,negate,value}],default,egress}]. Cached per daemon (fetch() too): dropped when the
    // daemon goes or comes, on ConfigChanged and when voiceModels() sees the installed set change.
    Q_INVOKABLE QVariantList configSchema();
    Q_INVOKABLE QVariantMap  getConfig();                // GetConfig() -> {key:value, ...}
    Q_INVOKABLE QVariantMap  setConfig(const QString &key, const QString &value); // SetConfig(s,s)
    // Restart() -> ok:restarting <unit> | busy:<why> | error:<how to restart by hand>.
    Q_INVOKABLE QVariantMap  restartDaemon();

    // --- typed wrappers: Settings -> Debug -> Heartbeat --------------------
    // Header of the most recent captured hourly analytics heartbeat.
    // HeartbeatInfo(s) -> {kind,ok,notready,unknown,label,watchTs,rx,size,version,buildId,fw,
    //                      known,metricCount}. `known` false = stoandl has no verified layout for
    // this (size, version), so the record is captured raw but nothing is decoded from it.
    Q_INVOKABLE QVariantMap  heartbeatInfo(const QString &watch = QString());
    // Every metric of that record, pre-grouped by the name prefix before the first '_' (record
    // order kept, both for the groups and within them):
    // -> [{group,label,metrics:[{name,value,text,raw,display,rawDiffers}]}].
    // Empty when there is no heartbeat, or when its layout is unverified — the daemon never
    // emits guessed values, so there is nothing to show.
    Q_INVOKABLE QVariantList heartbeatMetrics(const QString &watch = QString());

    // --- typed wrappers: Notifications screen ------------------------------
    // -> [{name,mute,muted,muteKind,mutedUntil,color,icon,vibe,lastNotified,appNamePlacement,imagesOff}]; muteKind is
    // never|always|weekdays|weekends|until (mutedUntil = epoch seconds it ends, for `until`).
    Q_INVOKABLE QVariantList notifList();
    Q_INVOKABLE QVariantMap  notifSetMute(const QString &name, const QString &spec);   // NotifSetMute(s,s)
    Q_INVOKABLE QVariantMap  notifSetMuteAll(const QString &spec);                      // NotifSetMuteAll(s), then mutedUntil
    Q_INVOKABLE void         refreshMuteAll();           // NotifMuteAllStatus() → mutedUntil (async)
    Q_INVOKABLE QVariantMap  notifSetStyle(const QString &name, const QString &color,
                                           const QString &icon, const QString &vibe);   // NotifSetStyle(s,s,s,s)
    // -> {vibes:[{text,value,pattern,custom}], icons:[{text,value}]}; cached for the daemon running now.
    Q_INVOKABLE QVariantMap  notifStyleChoices();
    Q_INVOKABLE QVariantMap  notifVibeTest(const QString &spec);                        // NotifVibeTest(s)
    // NotifSetVibePattern(s,s): add or replace a custom vibration (on/off ms CSV); an empty pattern removes it.
    Q_INVOKABLE QVariantMap  notifSetVibePattern(const QString &name, const QString &pattern);
    Q_INVOKABLE QVariantMap  notifSetAppName(const QString &name, const QString &placement); // NotifSetAppName(s,s)
    Q_INVOKABLE QVariantMap  notifSetImages(const QString &name, const QString &mode); // NotifSetImages(s,s)
    // HOOK (notifications) — regex filters.
    Q_INVOKABLE QVariantList notifListFilters();         // -> [{pattern,action}]
    Q_INVOKABLE QVariantMap  notifAddFilter(const QString &pattern, const QString &action);
    Q_INVOKABLE QVariantMap  notifRemoveFilter(const QString &pattern);

    // --- typed wrappers: Health screen (read-only) — HOOK #8 ---------------
    // Period-aware (periodType ∈ "day"|"week"|"month", offset = periods back, 0 = current).
    Q_INVOKABLE QVariantMap  healthSummary(const QString &periodType, int offset); // -> 20-field period summary
    Q_INVOKABLE QVariantList stepsBars(const QString &periodType, int offset);     // week/month -> [{label,value,typical,hasValue}]
    Q_INVOKABLE QVariantList sleepTimeline(const QString &periodType, int offset); // day -> [{start,width,deep}]
    Q_INVOKABLE QVariantList sleepBars(const QString &periodType, int offset);     // week/month -> [{label,value(totalMin),deep,hasValue}]
    Q_INVOKABLE QVariantList heartSamples(const QString &periodType, int offset);  // day -> [{minute(0-1439),bpm}]
    Q_INVOKABLE QVariantList heartBars(const QString &periodType, int offset);     // week/month -> [{label,value(avgBpm),hasValue}]

    // --- typed wrappers: System screen (Milestone 5) -----------------------
    // Firmware check: asynchronous, never on the UI thread (with firmware.github on, the daemon can take
    // 8+ s to answer). The result lands in firmwareInfo. `watchKey` is the name:state of every listed
    // watch: an unchanged key reuses the cached answer (or joins the call in flight), a changed one (a
    // watch connects, reboots after a flash, comes up in recovery) checks again.
    Q_INVOKABLE void         requestFirmwareCheck(const QString &watchKey);
    // An explicit "check now" (Sync now, Check for updates): re-asks the daemon for the last key even
    // when an answer is cached, through CheckFirmwareForce (past the daemon's own cache too).
    Q_INVOKABLE void         forceFirmwareCheck();
    // Firmware flash (async -> firmwareStatus poll, 0.8 s, 600 s ceiling).
    Q_INVOKABLE QVariantMap  updateFirmware();           // UpdateFirmware() ; on ok starts the firmware poll
    Q_INVOKABLE QVariantMap  sideloadFirmware(const QUrl &fileUrl); // SideloadFirmware(.pbz abs path) ; starts poll
    Q_INVOKABLE void         stopFirmwarePoll();

    // Language packs (install is async -> languageStatus poll, 0.6 s, 180 s ceiling).
    Q_INVOKABLE QVariantList listLanguages();            // -> [{id,isoLocal,displayName,installed,source}]
    Q_INVOKABLE QVariantMap  installLanguage(const QString &query); // InstallLanguage() ; on ok starts the poll
    Q_INVOKABLE QVariantMap  sideloadLanguage(const QUrl &fileUrl); // SideloadLanguage(.pbl abs path) ; starts poll
    Q_INVOKABLE void         stopLanguagePoll();

    // Diagnostics: watch tasks. The call returns the start ({kind ok|busy|notready|error, tail}); the
    // daemon picks a new file (Pictures/Screenshots, Documents/stoandl), and the result arrives as
    // taskFinished(kind, …): screenshot {kind, path, width, height}, logs {kind, path}.
    Q_INVOKABLE QVariantMap  takeScreenshot();
    Q_INVOKABLE QVariantMap  gatherLogs();
    // Open a daemon-written file, or the folder holding it, in the desktop's app for it.
    Q_INVOKABLE void         openFile(const QString &path);
    Q_INVOKABLE void         openFolderOf(const QString &path);

    // Reset (fire-and-forget; ok: = queued, not done).
    Q_INVOKABLE QVariantMap  resetIntoRecovery();        // ResetIntoRecovery()
    Q_INVOKABLE QVariantMap  factoryReset();             // FactoryReset() (destructive; GUI owns confirmation)

    // CLI shell-outs (NOT on D-Bus): co-located `stoandl` binary. Async -> cliResult.
    Q_INVOKABLE void         backup(const QUrl &outFile);   // stoandl backup [path]
    Q_INVOKABLE void         restore(const QUrl &inFile);   // stoandl restore <path>
    Q_INVOKABLE void         supportBundle(const QUrl &outFile); // stoandl support [path]

    // --- polling control (driven by the Watch page lifecycle) --------------
    Q_INVOKABLE void startWatchPoll();   // 20 s safety-net poll of ListWatches (+ BluetoothStatus)
    Q_INVOKABLE void stopWatchPoll();
    // Asynchronous re-read of ListWatches (with BluetoothStatus and LinkPause) → watchesChanged; call after
    // any mutation. The latest refresh wins.
    Q_INVOKABLE void refreshWatches();

    Q_INVOKABLE void startPairPoll();    // begin the PairStatus poll (after Pair/Repair)
    Q_INVOKABLE void stopPairPoll();

    // --- daemon lifecycle --------------------------------------------------
    // systemctl --user reset-failed stoandl, then systemctl --user start stoandl (async). The
    // reset clears a tripped StartLimitBurst, which otherwise makes the start fail. A start that
    // fails (or a systemctl that can't run, e.g. inside the flatpak) emits daemonStartFailed.
    Q_INVOKABLE void startDaemon();
    // NameHasOwner probe: at start and after startDaemon(); NameOwnerChanged tracks the name otherwise.
    Q_INVOKABLE void recheckDaemon();

Q_SIGNALS:
    void daemonUpChanged();
    void daemonStateChanged();
    void bluetoothOnChanged();                       // host Bluetooth on/off (BluetoothStatus, watch tick)
    void linkPauseChanged();
    void watchesChanged(const QVariantList &rows);   // WatchesChanged signal + 20 s safety-net poll
    void pairStatus(const QString &kind, const QString &msg); // Pair/Repair poll
    void findWatchResult(bool ok);
    void appsChanged(const QVariantList &rows);      // ListApps refresh (Apps screen)
    void extensionsChanged(const QVariantList &rows); // ExtList refresh (Plugins screen)
    void pluginsChanged(const QVariantList &rows);    // PluginList refresh
    void permissionRequestsChanged(const QVariantList &rows); // PermPending refresh
    void calendarsChanged(const QVariantList &rows);  // ListCalendars refresh (Sync screen)
    // System screen. Normalised kinds: progress = idle/downloading/waiting/inprogress/prf
    // (firmware; `prf` = a downgrade rebooting into recovery, detail = the target version, held
    // until the flash resumes from recovery) or idle/downloading/installing (language); terminal =
    // success/failed/timeout (firmware) or success/failed/disconnected/timeout (language).
    void firmwareStatus(const QString &kind, int percent, const QString &detail);
    void languageStatus(const QString &kind, int percent, const QString &detail);
    void cliResult(const QString &op, bool ok, const QString &message);
    void daemonStartFailed(const QString &message);  // startDaemon() could not start the service
    void firmwareInfoChanged();                      // firmwareInfo / firmwareChecking
    void callsInFlightChanged();
    void appIconChanged(const QString &uuid, const QString &url); // an appIcon() miss was answered
    // ConfigChanged(key): a stoandl.conf key was written (by any client, or the daemon itself). Pages
    // re-read GetConfig (and the schema, which this drops from the cache).
    void configChanged(const QString &key);
    void forwardingChanged();
    void restartPendingChanged();
    void daemonVersionChanged();
    void mutedUntilChanged();
    void busyOpChanged();
    void readErrorsChanged();
    void tasksChanged();
    // A watch task this GUI started ended: its TaskStatus result as a status map, plus {path, width, height}
    // for a screenshot and {path} for logs and a core dump.
    void taskFinished(const QString &kind, const QVariantMap &result);

private Q_SLOTS:
    void onNameOwnerChanged(const QString &name, const QString &oldOwner, const QString &newOwner);
    // Reactive D-Bus signals (de.yoxcu.stoandl.Control) — augment polling, never replace it
    // (the daemon isn't D-Bus-activated, so a late/reconnecting client can miss a signal).
    void onWatchesChanged();                                          // poke → refreshWatches()
    void onFirmwareProgress(const QString &phase, int percent, const QString &detail); // → firmwareStatus()
    void onLockerChanged();                                           // poke → refreshApps()
    void onCalendarsChanged();                                        // poke → refreshCalendars()
    void onLanguageProgress(const QString &phase, int percent, const QString &detail); // → languageStatus()
    void onExtensionsChanged();                                       // poke → refreshExtensions()
    void onPluginsChanged();                                          // PluginsChanged / PermissionRequestsChanged → refreshPlugins()
    // Finer companion to ExtensionsChanged: an unsolicited per-extension run-state transition
    // (ready / exited / quarantined) the list-level poke can't carry. Records the state and
    // re-syncs the list (the override is merged into the rows extList() builds).
    void onExtensionStateChanged(const QString &name, const QString &state);
    void onConfigChanged(const QString &key);                         // → configChanged(), forwarding
    void onTaskChanged(const QString &kind, const QString &status);   // → tasks, taskFinished()
    void pollPairOnce();
    void firmwarePollOnce();
    void languagePollOnce();

private:
    QDBusMessage methodCall(const QString &method, const QVariantList &args) const;
    Status       callStatus(const QString &method, const QVariantList &args = {});
    // Record (or clear) the D-Bus failure of the typed read `name` in readErrors.
    void         noteReadResult(const QString &name, const QDBusMessage &reply);
    // The typed reads fetch() can run (readSpec() in the .cpp: each one's D-Bus call and parser). The
    // synchronous Q_INVOKABLE of that name runs it through read(), so both paths share one description.
    QVariant     read(const QString &name, const QVariantList &args = {});
    // read() without blocking: `done` gets the value, unless `context` (when given) died first. `user`
    // counts it in userCallsInFlight (someone waits for it).
    void         readAsync(const QString &name, const QVariantList &args, QObject *context,
                           const std::function<void(const QVariant &)> &done, bool user = false);
    // What a read's answer starts beyond its value (updateFirmware: the flash poll; voiceModels: a changed
    // installed set drops the cached schema). Both read() and readAsync() run it.
    void         afterRead(const QString &name, const QVariant &value);
    // One D-Bus call without blocking, counted in callsInFlight (and userCallsInFlight when `user`);
    // `done` is skipped if `context` died. timeoutMs 0 = the ordinary timeout.
    void         callAsync(const QDBusMessage &message, QObject *context,
                           const std::function<void(const QDBusMessage &)> &done,
                           bool user = false, int timeoutMs = 0);
    // Hand `value` to a QML callback (fetch(), run()).
    void         callBack(const QJSValue &callback, const QVariant &value);
    // Start a watch task: `ok:started` tracks it (tasks, TaskChanged, the fallback poll); a daemon from
    // before the tasks answers with the result itself, which is reported as finished at once.
    QVariantMap  startTask(const QString &kind, const QString &method, const QVariantList &args);
    void         taskStatusSeen(const QString &kind, const QString &status);
    void         pollTasks();
    // ExtList rows with the ExtensionStateChanged overrides merged in (and stale overrides pruned).
    QVariantList withExtState(QVariantList rows);
    void         startFirmwarePoll();
    // Stop the firmware poll and clear its activity/recovery state (every terminal outcome).
    void         endFirmwareOp();
    void         startLanguagePoll();
    // Normalise a raw firmware phase (FirmwareStatus kind OR FirmwareProgress phase) to the
    // terminal/progress `kind` the QML expects and Q_EMIT firmwareStatus. Shared by the poll
    // loop and the FirmwareProgress signal so both map reboot→success, post-activity notready→
    // success, failed→failed identically, and ignore an idle/notready poke when nothing's in flight.
    void         emitFirmwareStatus(const QString &phase, int percent, const QString &detail);
    // Normalise a raw language phase (LanguageStatus kind OR LanguageProgress phase) to the
    // terminal/progress `kind` the QML expects and Q_EMIT languageStatus. Shared by the poll
    // loop and the LanguageProgress signal so both map done→success, post-activity notready→
    // disconnected, failed→failed identically. (The first-poll stale-terminal skip stays in
    // languagePollOnce — it guards a stale poll snapshot; the signal is always live.)
    void         emitLanguageStatus(const QString &phase, int percent, const QString &detail);
    // Issue one asynchronous CheckFirmware for m_fwWantedKey (nothing else in flight).
    void         startFirmwareCheck(bool force);
    // Forget the cached firmware answer (daemon gone, a flash finished): the next request re-asks.
    void         clearFirmwareInfo(bool forgetKey);
    static QVariantMap firmwareInfoMap(const Status &s);
    void         setDaemonUp(bool up);
    // Read notification.forward (asynchronously) into m_forwarding.
    void         refreshForwarding();
    // Forget the cached answer of the read `name` (empty = every cached read).
    void         dropCache(const QString &name = QString());
    void         runCli(const QString &op, const QStringList &args);
    // Run `systemctl --user <args>` asynchronously; `done` gets (exit 0, first stderr line / reason, stdout).
    void         runSystemctl(const QStringList &args,
                              const std::function<void(bool ok, const QString &message, const QString &out)> &done);
    // Ask systemd why the daemon isn't running (m_serviceState), unless it is up or starting.
    void         probeService();
    void         setInstanceUp(bool up);
    void         setMutedUntil(qint64 epochSeconds);
    // Emit busyOpChanged if a pair, firmware or language poll started or stopped.
    void         opPollsChanged();

    QDBusConnection m_bus;
    bool            m_daemonUp = false;
    // The daemon's private instance name is owned: it is running, and starting when the public name
    // isn't owned yet (the daemon takes that last).
    bool            m_instanceUp = false;
    // probeService()'s answer: stopped | failed | startlimit | notinstalled | nosystemd.
    QString         m_serviceState = QStringLiteral("stopped");
    bool            m_bluetoothOn = true;   // assume on until the first BluetoothStatus poll says otherwise
    QString         m_linkPause;

    QTimer *m_watchTimer = nullptr;
    QTimer *m_pairTimer  = nullptr;
    int     m_pairElapsedMs = 0;

    QTimer *m_fwTimer = nullptr;
    int     m_fwElapsedMs = 0;
    bool    m_fwSeenActivity = false;
    // A downgrade going through recovery (`prf:<version>`): the reboot into PRF drops the link
    // before anything is flashed, so that disconnect is NOT success. Set on the first prf phase
    // (activity + timeout restart there), cleared at the terminal state.
    bool    m_fwViaRecovery = false;
    QString m_fwPrfVersion;

    // CheckFirmware cache: m_fwInfo answers m_fwInfoKey; m_fwWantedKey is what the page asked for last.
    // One call at a time: a request for another key (or a forced one) while a call is in flight is
    // queued and issued when it returns, so a slow daemon never stacks downloads. A good answer is kept
    // until the key changes; a failed one (kind error) only for FW_ERROR_REUSE_MS of m_fwInfoAge.
    QVariantMap m_fwInfo;
    QString     m_fwInfoKey;
    QString     m_fwWantedKey;
    bool        m_fwHaveInfo = false;
    QElapsedTimer m_fwInfoAge;                  // since m_fwInfo arrived
    bool        m_fwCheckInFlight = false;
    bool        m_fwForceQueued = false;
    bool        m_fwForceUnsupported = false;   // the daemon predates CheckFirmwareForce
    quint64     m_fwGeneration = 0;   // bumped by clearFirmwareInfo: a reply from before is dropped

    QTimer *m_langTimer = nullptr;
    int     m_langElapsedMs = 0;
    bool    m_langSeenActivity = false;
    bool    m_langFirstPoll = true;

    int     m_callsInFlight = 0;
    int     m_userCallsInFlight = 0;
    // Watch tasks started here and still running (kind → what), how long each has run, and the fallback
    // poll of TaskStatus for a TaskChanged this client missed.
    QVariantMap m_tasks;
    QHash<QString, QElapsedTimer> m_taskAge;
    QTimer *m_taskTimer = nullptr;
    // fetch(): the latest fetch per owner (an older one's answer is dropped).
    QHash<QObject *, quint64> m_fetchSeq;
    quint64 m_fetchCounter = 0;
    // refresh*(): the latest reload of each list, so a slow older answer can't overwrite a newer one.
    quint64 m_appsSeq = 0;
    quint64 m_extSeq = 0;
    quint64 m_pluginsSeq = 0;
    quint64 m_calendarsSeq = 0;
    quint64 m_watchesSeq = 0;
    // appIcon(): uuid → {file URL or "" for none, when it was answered}; uuids being asked.
    struct IconEntry { QString url; qint64 answeredMs = 0; };
    QHash<QString, IconEntry> m_icons;
    QSet<QString> m_iconPending;

    // Per-extension runtime state from ExtensionStateChanged (name → ready|exited|quarantined).
    // Merged into the extList() rows so a quarantined/exited extension isn't shown as a stale
    // "running" (the polled ExtList keeps a quarantined ext in its `running` map). Entries are
    // pruned in extList() when ExtList no longer lists that name.
    QHash<QString, QString> m_extState;

    bool        m_forwarding = true;
    QStringList m_restartPending;
    QString     m_daemonVersion;
    qint64      m_mutedUntil = 0;
    QTimer     *m_muteEndTimer = nullptr;   // drops mutedUntil to 0 when it passes
    QString     m_lastBusyOp;
    QVariantMap m_readErrors;
    // The cached reads' answers (readSpec's `cached`: the config schema, the notification styles) for the
    // daemon running now; m_cacheGeneration drops an answer to a call that started before a drop.
    QHash<QString, QVariant> m_cache;
    quint64     m_cacheGeneration = 0;
    // The installed speech models and voices voiceModels() last saw ("" before the first read).
    QString     m_installedModels;
};
