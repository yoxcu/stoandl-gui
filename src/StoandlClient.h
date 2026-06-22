#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QDBusConnection>
#include <QVariantList>
#include <QVariantMap>
#include <QStringList>
#include <QHash>
#include <QUrl>

class QTimer;

// The ONLY object that touches D-Bus. Registered as a QML singleton
// (`StoandlClient` in module org.stoandl.gui). Three jobs: call, parse, poll.
//
// Contract: de.yoxcu.stoandl.Control on the *session* bus, path /de/yoxcu/stoandl.
// The interface exposes three reactive signals (WatchesChanged/FirmwareProgress/
// LockerChanged) that augment polling; polling stays as the fallback (the daemon is not
// D-Bus-activated, so a late/reconnecting client can miss a signal). The QML never polls
// and never parses — all of that lives here. See docs/handoff/dbus-interface.md.
class StoandlClient : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(bool daemonUp READ daemonUp NOTIFY daemonUpChanged)
    // Host Bluetooth on/usable (BluetoothStatus, polled on the 20 s watch tick). The daemon detects
    // adapter-off / rfkill / airplane-mode; the GUI shows a "Bluetooth is off" state when this is false.
    Q_PROPERTY(bool bluetoothOn READ bluetoothOn NOTIFY bluetoothOnChanged)

public:
    explicit StoandlClient(QObject *parent = nullptr);

    bool daemonUp() const { return m_daemonUp; }
    bool bluetoothOn() const { return m_bluetoothOn; }

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

    // --- typed wrappers: Watch screen --------------------------------------
    Q_INVOKABLE QVariantList listWatches();              // -> [{name,state,battery,transport,connected}]
    Q_INVOKABLE QVariantMap  battery();                  // Battery()  -> status map
    Q_INVOKABLE QVariantMap  connectWatch(const QString &name); // Connect(s)
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
    Q_INVOKABLE QVariantMap  getCoreDump();              // GetCoreDump(tmp) -> {kind, path}

    // --- typed wrappers: Apps & Faces screen (Milestone 2) -----------------
    Q_INVOKABLE QVariantList listApps();                 // -> [{uuid,type,order,title,developer,flags[],active,system,config,sideloaded,isFace}]
    Q_INVOKABLE QVariantMap  launchApp(const QString &id);   // LaunchApp(s)
    Q_INVOKABLE QVariantMap  removeApp(const QString &id);   // RemoveApp(s) (system refused daemon-side)
    Q_INVOKABLE QVariantMap  sideloadApp(const QUrl &fileUrl); // SideloadApp(absolute daemon-side path)
    Q_INVOKABLE QVariantMap  openConfig(const QString &id);  // OpenConfig(s) -> open the URL via xdg-open (v1: skip WebviewClose)
    Q_INVOKABLE void         refreshApps();              // re-fetch + appsChanged (on show + after any mutation)

    // --- typed wrappers: Extensions (Apps screen, 3rd segment) -------------
    Q_INVOKABLE QVariantList extList();                  // -> [{name,installed,enabled,running,config,description}]
    Q_INVOKABLE QVariantMap  extEnable(const QString &name);   // ExtEnable(s)
    Q_INVOKABLE QVariantMap  extDisable(const QString &name);  // ExtDisable(s)
    Q_INVOKABLE QVariantMap  extRestart(const QString &name);  // ExtRestart(s)
    Q_INVOKABLE QVariantMap  extUninstall(const QString &name, bool keepConfig); // ExtUninstall(s,b)
    Q_INVOKABLE QVariantMap  extInstall(const QUrl &archiveUrl); // ExtInstall(absolute daemon-side path)
    Q_INVOKABLE void         refreshExtensions();        // re-fetch + extensionsChanged (on show + after any mutation)
    // HOOK #7 — extension config, two backends (url | schema).
    Q_INVOKABLE QVariantMap  extOpenConfig(const QString &name);   // ExtOpenConfig(s) -> xdg-open url; {kind,url,opened,msg}
    Q_INVOKABLE QVariantList extConfigSchema(const QString &name); // ExtConfigSchema(s) -> [{key,type,label,secret,options[]}]
    Q_INVOKABLE QVariantMap  extGetConfig(const QString &name);    // ExtGetConfig(s)   -> {key:value, ...}
    Q_INVOKABLE QVariantMap  extSetConfig(const QString &name, const QVariantMap &values); // ExtSetConfig(s, json)

    // --- typed wrappers: Sync services (Settings screen) -------------------
    Q_INVOKABLE QVariantMap  syncWeather();              // SyncWeather() ; error: if disabled in config
    Q_INVOKABLE QVariantMap  syncCalendar();             // SyncCalendar()
    Q_INVOKABLE QVariantMap  syncHealth();               // SyncHealth()
    Q_INVOKABLE QVariantList listCalendars();            // -> [{id,name,enabled}]
    Q_INVOKABLE QVariantMap  setCalendarEnabled(const QString &id, bool enabled); // SetCalendarEnabled(s,b)
    Q_INVOKABLE void         refreshCalendars();         // re-fetch + calendarsChanged (on show + after toggle)
    // HOOK #5 — per-service master toggles + status.
    Q_INVOKABLE QVariantList getSyncStatus();            // -> [{service,enabled,available,lastSync}]
    Q_INVOKABLE QVariantMap  setSyncEnabled(const QString &service, bool enabled); // SetSyncEnabled(s,b)

    // --- typed wrappers: Watch settings (Settings screen) ------------------
    Q_INVOKABLE QVariantList listWatchPrefs();           // -> [{id,type,current,default,allowed[],flags[],name,description}]
    Q_INVOKABLE QVariantMap  setWatchPref(const QString &id, const QString &value); // SetWatchPref(s,s)

    // --- typed wrappers: Daemon config (Settings -> Advanced) — HOOK #10 ---
    Q_INVOKABLE QVariantList configSchema();             // GetConfigSchema() -> [{key,type,label,options[],desc}]
    Q_INVOKABLE QVariantMap  getConfig();                // GetConfig() -> {key:value, ...}
    Q_INVOKABLE QVariantMap  setConfig(const QString &key, const QString &value); // SetConfig(s,s)

    // --- typed wrappers: Notifications screen ------------------------------
    Q_INVOKABLE QVariantList notifList();                // -> [{name,mute,muted,color,icon,vibe,lastNotified}]
    Q_INVOKABLE QVariantMap  notifSetMute(const QString &name, const QString &spec);   // NotifSetMute(s,s)
    Q_INVOKABLE QVariantMap  notifSetMuteAll(const QString &spec);                      // NotifSetMuteAll(s)
    Q_INVOKABLE QVariantMap  notifSetStyle(const QString &name, const QString &color,
                                           const QString &icon, const QString &vibe);   // NotifSetStyle(s,s,s,s)
    // HOOK (notifications) — regex filters.
    Q_INVOKABLE QVariantList notifListFilters();         // -> [{pattern,action}]
    Q_INVOKABLE QVariantMap  notifAddFilter(const QString &pattern, const QString &action);
    Q_INVOKABLE QVariantMap  notifRemoveFilter(const QString &pattern);

    // --- typed wrappers: Health screen (read-only) — HOOK #8 ---------------
    Q_INVOKABLE QVariantMap  healthSummary();            // GetHealthSummary() -> today totals + trends + hrAvailable
    Q_INVOKABLE QVariantList healthSeries(const QString &metric); // GetHealthSeries(steps|sleep|heart) -> [{label,value,hasValue}]

    // --- typed wrappers: System screen (Milestone 5) -----------------------
    // Firmware (flash is async -> firmwareStatus poll, 0.8 s, 600 s ceiling).
    Q_INVOKABLE QVariantMap  checkFirmware();            // CheckFirmware() -> {kind, board,current,latest,asset,updateAvailable,source}
    Q_INVOKABLE QVariantMap  updateFirmware();           // UpdateFirmware() ; on ok starts the firmware poll
    Q_INVOKABLE QVariantMap  sideloadFirmware(const QUrl &fileUrl); // SideloadFirmware(.pbz abs path) ; starts poll
    Q_INVOKABLE void         stopFirmwarePoll();

    // Language packs (install is async -> languageStatus poll, 0.6 s, 180 s ceiling).
    Q_INVOKABLE QVariantList listLanguages();            // -> [{id,isoLocal,displayName,installed,source}]
    Q_INVOKABLE QVariantMap  installLanguage(const QString &query); // InstallLanguage() ; on ok starts the poll
    Q_INVOKABLE QVariantMap  sideloadLanguage(const QUrl &fileUrl); // SideloadLanguage(.pbl abs path) ; starts poll
    Q_INVOKABLE void         stopLanguagePoll();

    // Diagnostics (write a daemon-side file, return its path; GUI is co-located).
    Q_INVOKABLE QVariantMap  takeScreenshot();           // TakeScreenshot(tmp) -> {kind, path, width, height}
    Q_INVOKABLE QVariantMap  gatherLogs();               // GatherLogs(tmp) -> {kind, path}

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
    Q_INVOKABLE void refreshWatches();   // immediate poll + watchesChanged (call after any mutation)

    Q_INVOKABLE void startPairPoll();    // begin the PairStatus poll (after Pair/Repair)
    Q_INVOKABLE void stopPairPoll();

    // --- daemon lifecycle --------------------------------------------------
    Q_INVOKABLE bool startDaemon();      // systemctl --user start stoandl
    Q_INVOKABLE void recheckDaemon();    // NameHasOwner probe

Q_SIGNALS:
    void daemonUpChanged();
    void bluetoothOnChanged();                       // host Bluetooth on/off (BluetoothStatus, watch tick)
    void watchesChanged(const QVariantList &rows);   // WatchesChanged signal + 20 s safety-net poll
    void pairStatus(const QString &kind, const QString &msg); // Pair/Repair poll
    void findWatchResult(bool ok);
    void appsChanged(const QVariantList &rows);      // ListApps refresh (Apps screen)
    void extensionsChanged(const QVariantList &rows); // ExtList refresh (Plugins screen)
    void calendarsChanged(const QVariantList &rows);  // ListCalendars refresh (Sync screen)
    // System screen. Normalised kinds: progress = idle/downloading/waiting/inprogress
    // (firmware) or idle/downloading/installing (language); terminal = success/failed/
    // timeout (firmware) or success/failed/disconnected/timeout (language).
    void firmwareStatus(const QString &kind, int percent, const QString &detail);
    void languageStatus(const QString &kind, int percent, const QString &detail);
    void cliResult(const QString &op, bool ok, const QString &message);

private Q_SLOTS:
    void onNameOwnerChanged(const QString &name, const QString &oldOwner, const QString &newOwner);
    // Reactive D-Bus signals (de.yoxcu.stoandl.Control) — augment polling, never replace it
    // (the daemon isn't D-Bus-activated, so a late/reconnecting client can miss a signal).
    void onWatchesChanged();                                          // poke → refreshWatches()
    void onFirmwareProgress(const QString &phase, int percent, const QString &detail); // → firmwareStatus()
    void onLockerChanged();                                           // poke → refreshApps()
    void onLanguageProgress(const QString &phase, int percent, const QString &detail); // → languageStatus()
    void onExtensionsChanged();                                       // poke → refreshExtensions()
    // Finer companion to ExtensionsChanged: an unsolicited per-extension run-state transition
    // (ready / exited / quarantined) the list-level poke can't carry. Records the state and
    // re-syncs the list (the override is merged into the rows extList() builds).
    void onExtensionStateChanged(const QString &name, const QString &state);
    void pollPairOnce();
    void firmwarePollOnce();
    void languagePollOnce();

private:
    QDBusMessage methodCall(const QString &method, const QVariantList &args) const;
    Status       callStatus(const QString &method, const QVariantList &args = {});
    static Status parseStatus(const QString &s);
    static QVariantMap statusMap(const Status &s);
    static int   parsePercent(const QString &s);
    void         startFirmwarePoll();
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
    void         runCli(const QString &op, const QStringList &args);

    QDBusConnection m_bus;
    bool            m_daemonUp = false;
    bool            m_bluetoothOn = true;   // assume on until the first BluetoothStatus poll says otherwise

    QTimer *m_watchTimer = nullptr;
    QTimer *m_pairTimer  = nullptr;
    int     m_pairElapsedMs = 0;

    QTimer *m_fwTimer = nullptr;
    int     m_fwElapsedMs = 0;
    bool    m_fwSeenActivity = false;

    QTimer *m_langTimer = nullptr;
    int     m_langElapsedMs = 0;
    bool    m_langSeenActivity = false;
    bool    m_langFirstPoll = true;

    // Per-extension runtime state from ExtensionStateChanged (name → ready|exited|quarantined).
    // Merged into the extList() rows so a quarantined/exited extension isn't shown as a stale
    // "running" (the polled ExtList keeps a quarantined ext in its `running` map). Entries are
    // pruned in extList() when ExtList no longer lists that name.
    QHash<QString, QString> m_extState;
};
