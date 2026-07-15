//! `StoandlClient` — the one object that touches D-Bus (GObject analogue of the
//! Qt `StoandlClient` shim). Owns the session-bus `DBusConnection`, exposes
//! `daemon-up`/`bluetooth-on` properties + the reactive push signals, subscribes
//! to the Control signals, keeps the safety-net pollers, and offers typed async
//! calls. Parsing lives in `parse.rs` — never in the UI. See ARCHITECTURE.md.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::ffi::OsStr;
use std::time::Duration;

use gtk::gio;
use gtk::glib;
use gtk::glib::prelude::*;
use gtk::subclass::prelude::*;

use crate::config::{CALL_TIMEOUT_MS, DBUS_IFACE, DBUS_NAME, DBUS_PATH, FIND_TIMEOUT_MS};
use crate::dbus::parse::{
    parse_apps, parse_calendar_sources, parse_calendars, parse_config_schema, parse_config_values,
    parse_ext_list, parse_ext_schema, parse_firmware_info, parse_health_summary, parse_heart_bars,
    parse_heart_samples, parse_languages, parse_notif_filters, parse_notif_list, parse_open_config,
    parse_percent, parse_sleep_bars, parse_sleep_timeline, parse_status, parse_step_bars,
    parse_sync_status, parse_watch_details, parse_watch_prefs, parse_watches, AppRow, Calendar,
    CalendarSource, ConfigField, ExtField, ExtRow, FirmwareInfo, HealthSummary, HeartBar,
    HeartSample, LanguageRow, NotifApp, NotifFilter, SleepBar, SleepSegment, Status, StepBar,
    SyncStatus, WatchDetails, WatchPref, WatchRow,
};

const FDO_NAME: &str = "org.freedesktop.DBus";
const FDO_PATH: &str = "/org/freedesktop/DBus";

// Poller cadences + ceilings (mirror the Qt StoandlClient constants).
const WATCH_INTERVAL_S: u32 = 20; // 20 s safety-net + BluetoothStatus carrier
const PAIR_INTERVAL_MS: u64 = 1_500;
const PAIR_TIMEOUT_MS: i32 = 145_000;
const FW_INTERVAL_MS: u64 = 800;
const FW_TIMEOUT_MS: i32 = 600_000;
const LANG_INTERVAL_MS: u64 = 3_000; // watchdog cadence (LanguageProgress carries the live %)
const LANG_TIMEOUT_MS: i32 = 180_000;

mod imp {
    use super::*;
    use glib::Properties;
    use std::sync::OnceLock;

    #[derive(Properties, Default)]
    #[properties(wrapper_type = super::StoandlClient)]
    pub struct StoandlClient {
        #[property(get, name = "daemon-up")]
        pub daemon_up: Cell<bool>,
        #[property(get, name = "bluetooth-on")]
        pub bluetooth_on: Cell<bool>,

        pub connection: RefCell<Option<gio::DBusConnection>>,

        // Latest ListWatches snapshot (parsed). The page reads it in the
        // `watches-changed` handler; `connected_watch()` derives the active row.
        pub watches: RefCell<Vec<WatchRow>>,
        // Latest ListApps + ExtList snapshots; and the per-extension run-state
        // override map fed by ExtensionStateChanged (merged into the ext rows).
        pub apps: RefCell<Vec<AppRow>>,
        pub extensions: RefCell<Vec<ExtRow>>,
        pub ext_state: RefCell<HashMap<String, String>>,
        // uuid → resolved icon path (None = daemon has no icon). Avoids re-issuing
        // GetAppIcon for the same app on every locker rebuild.
        pub icon_cache: RefCell<HashMap<String, Option<String>>>,
        // Latest ListCalendars snapshot (read in the calendars-changed handler).
        pub calendars: RefCell<Vec<Calendar>>,

        // Poller source ids (None = not running).
        pub watch_poll: RefCell<Option<glib::SourceId>>,
        pub pair_poll: RefCell<Option<glib::SourceId>>,
        pub fw_poll: RefCell<Option<glib::SourceId>>,
        pub lang_poll: RefCell<Option<glib::SourceId>>,

        // Poller state.
        pub pair_elapsed: Cell<i32>,
        pub fw_elapsed: Cell<i32>,
        pub fw_seen_activity: Cell<bool>,
        pub lang_elapsed: Cell<i32>,
        pub lang_seen_activity: Cell<bool>,
        pub lang_first_poll: Cell<bool>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for StoandlClient {
        const NAME: &'static str = "StoandlClient";
        type Type = super::StoandlClient;
    }

    #[glib::derived_properties]
    impl ObjectImpl for StoandlClient {
        fn constructed(&self) {
            self.parent_constructed();
            // Bluetooth is assumed present until a BluetoothStatus poll says "off"
            // (older daemons lack the method — never flash a false "BT off").
            self.bluetooth_on.set(true);
        }

        fn signals() -> &'static [glib::subclass::Signal] {
            static SIGNALS: OnceLock<Vec<glib::subclass::Signal>> = OnceLock::new();
            SIGNALS.get_or_init(|| {
                vec![
                    // Poke: ListWatches was re-fetched — the page reads client.watches().
                    glib::subclass::Signal::builder("watches-changed").build(),
                    // Locker/extensions re-fetched — pages read client.apps()/extensions().
                    glib::subclass::Signal::builder("apps-changed").build(),
                    glib::subclass::Signal::builder("extensions-changed").build(),
                    // Calendars re-fetched — the Calendars page reads client.calendars().
                    glib::subclass::Signal::builder("calendars-changed").build(),
                    // Pairing poll / signal: (kind, msg) — confirm:<code>, ok, error, timeout…
                    glib::subclass::Signal::builder("pair-status")
                        .param_types([String::static_type(), String::static_type()])
                        .build(),
                    glib::subclass::Signal::builder("find-watch-result")
                        .param_types([bool::static_type()])
                        .build(),
                    // Normalised firmware/language progress: (kind, percent, detail).
                    glib::subclass::Signal::builder("firmware-status")
                        .param_types([String::static_type(), i32::static_type(), String::static_type()])
                        .build(),
                    glib::subclass::Signal::builder("language-status")
                        .param_types([String::static_type(), i32::static_type(), String::static_type()])
                        .build(),
                ]
            })
        }
    }
}

glib::wrapper! {
    pub struct StoandlClient(ObjectSubclass<imp::StoandlClient>);
}

impl Default for StoandlClient {
    fn default() -> Self {
        Self::new()
    }
}

impl StoandlClient {
    pub fn new() -> Self {
        glib::Object::new()
    }

    fn connection(&self) -> Option<gio::DBusConnection> {
        self.imp().connection.borrow().clone()
    }

    fn set_daemon_up(&self, v: bool) {
        if self.imp().daemon_up.get() != v {
            self.imp().daemon_up.set(v);
            self.notify("daemon-up");
        }
    }

    fn set_bluetooth_on(&self, v: bool) {
        if self.imp().bluetooth_on.get() != v {
            self.imp().bluetooth_on.set(v);
            self.notify("bluetooth-on");
        }
    }

    // --- cached watch snapshot ------------------------------------------------

    /// The latest parsed ListWatches snapshot (read in the `watches-changed` handler).
    pub fn watches(&self) -> Vec<WatchRow> {
        self.imp().watches.borrow().clone()
    }

    /// The connected watch, if any (the hero card / Ring-watch gate).
    pub fn connected_watch(&self) -> Option<WatchRow> {
        self.imp().watches.borrow().iter().find(|w| w.connected).cloned()
    }

    // --- reactive signal connect helpers (ergonomic wrappers) ----------------

    pub fn connect_watches_changed<F: Fn(&Self) + 'static>(&self, f: F) {
        self.connect_closure(
            "watches-changed",
            false,
            glib::closure_local!(move |c: StoandlClient| f(&c)),
        );
    }

    pub fn connect_pair_status<F: Fn(&Self, &str, &str) + 'static>(&self, f: F) {
        self.connect_closure(
            "pair-status",
            false,
            glib::closure_local!(move |c: StoandlClient, kind: String, msg: String| f(
                &c, &kind, &msg
            )),
        );
    }

    pub fn connect_find_watch_result<F: Fn(&Self, bool) + 'static>(&self, f: F) {
        self.connect_closure(
            "find-watch-result",
            false,
            glib::closure_local!(move |c: StoandlClient, ok: bool| f(&c, ok)),
        );
    }

    pub fn connect_firmware_status<F: Fn(&Self, &str, i32, &str) + 'static>(&self, f: F) {
        self.connect_closure(
            "firmware-status",
            false,
            glib::closure_local!(move |c: StoandlClient, kind: String, pct: i32, detail: String| f(
                &c, &kind, pct, &detail
            )),
        );
    }

    pub fn connect_language_status<F: Fn(&Self, &str, i32, &str) + 'static>(&self, f: F) {
        self.connect_closure(
            "language-status",
            false,
            glib::closure_local!(move |c: StoandlClient, kind: String, pct: i32, detail: String| f(
                &c, &kind, pct, &detail
            )),
        );
    }

    // --- signal emit helpers --------------------------------------------------

    fn emit_watches_changed(&self) {
        self.emit_by_name::<()>("watches-changed", &[]);
    }
    fn emit_pair_status(&self, kind: &str, msg: &str) {
        self.emit_by_name::<()>("pair-status", &[&kind.to_string(), &msg.to_string()]);
    }
    fn signal_firmware_status(&self, kind: &str, percent: i32, detail: &str) {
        self.emit_by_name::<()>(
            "firmware-status",
            &[&kind.to_string(), &percent, &detail.to_string()],
        );
    }
    fn signal_language_status(&self, kind: &str, percent: i32, detail: &str) {
        self.emit_by_name::<()>(
            "language-status",
            &[&kind.to_string(), &percent, &detail.to_string()],
        );
    }

    // --- startup: connection, daemon liveness, reactive signals --------------

    pub fn start(&self) {
        let conn = match gio::bus_get_sync(gio::BusType::Session, gio::Cancellable::NONE) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("stoandl: session bus unavailable: {e}");
                return;
            }
        };
        self.imp().connection.replace(Some(conn.clone()));

        // Daemon appear/disappear without polling (arg0-filtered to our name).
        conn.signal_subscribe(
            Some(FDO_NAME),
            Some(FDO_NAME),
            Some("NameOwnerChanged"),
            Some(FDO_PATH),
            Some(DBUS_NAME),
            gio::DBusSignalFlags::NONE,
            glib::clone!(
                #[weak(rename_to = this)]
                self,
                move |_conn, _sender, _path, _iface, _signal, params| {
                    let new_owner: String = params.child_value(2).get().unwrap_or_default();
                    let up = !new_owner.is_empty();
                    this.set_daemon_up(up);
                    if up {
                        // Re-sync on daemon-up (missed-signal net; not D-Bus-activated).
                        glib::spawn_future_local(glib::clone!(
                            #[strong]
                            this,
                            async move { this.refresh_watches().await }
                        ));
                    }
                }
            ),
        );

        // Reactive Control signals — they AUGMENT polling (see CLAUDE.md hard rules).
        conn.signal_subscribe(
            Some(DBUS_NAME),
            Some(DBUS_IFACE),
            Some("WatchesChanged"),
            Some(DBUS_PATH),
            None,
            gio::DBusSignalFlags::NONE,
            glib::clone!(
                #[weak(rename_to = this)]
                self,
                move |_c, _s, _p, _i, _sig, _params| {
                    glib::spawn_future_local(glib::clone!(
                        #[strong]
                        this,
                        async move { this.refresh_watches().await }
                    ));
                }
            ),
        );
        conn.signal_subscribe(
            Some(DBUS_NAME),
            Some(DBUS_IFACE),
            Some("FirmwareProgress"),
            Some(DBUS_PATH),
            None,
            gio::DBusSignalFlags::NONE,
            glib::clone!(
                #[weak(rename_to = this)]
                self,
                move |_c, _s, _p, _i, _sig, params| {
                    let phase: String = params.child_value(0).get().unwrap_or_default();
                    let percent: i32 = params.child_value(1).get().unwrap_or(-1);
                    let detail: String = params.child_value(2).get().unwrap_or_default();
                    this.firmware_normalize(&phase, percent, &detail);
                }
            ),
        );
        conn.signal_subscribe(
            Some(DBUS_NAME),
            Some(DBUS_IFACE),
            Some("LanguageProgress"),
            Some(DBUS_PATH),
            None,
            gio::DBusSignalFlags::NONE,
            glib::clone!(
                #[weak(rename_to = this)]
                self,
                move |_c, _s, _p, _i, _sig, params| {
                    let phase: String = params.child_value(0).get().unwrap_or_default();
                    let percent: i32 = params.child_value(1).get().unwrap_or(-1);
                    let detail: String = params.child_value(2).get().unwrap_or_default();
                    this.language_normalize(&phase, percent, &detail);
                }
            ),
        );
        // LockerChanged → re-fetch apps; ExtensionsChanged → re-fetch extensions.
        conn.signal_subscribe(
            Some(DBUS_NAME),
            Some(DBUS_IFACE),
            Some("LockerChanged"),
            Some(DBUS_PATH),
            None,
            gio::DBusSignalFlags::NONE,
            glib::clone!(
                #[weak(rename_to = this)]
                self,
                move |_c, _s, _p, _i, _sig, _params| {
                    glib::spawn_future_local(glib::clone!(
                        #[strong]
                        this,
                        async move { this.refresh_apps().await }
                    ));
                }
            ),
        );
        conn.signal_subscribe(
            Some(DBUS_NAME),
            Some(DBUS_IFACE),
            Some("ExtensionsChanged"),
            Some(DBUS_PATH),
            None,
            gio::DBusSignalFlags::NONE,
            glib::clone!(
                #[weak(rename_to = this)]
                self,
                move |_c, _s, _p, _i, _sig, _params| {
                    glib::spawn_future_local(glib::clone!(
                        #[strong]
                        this,
                        async move { this.refresh_extensions().await }
                    ));
                }
            ),
        );
        // CalendarsChanged → re-fetch calendars (the daemon pokes it when an async
        // sync adds/drops calendars after a source CRUD).
        conn.signal_subscribe(
            Some(DBUS_NAME),
            Some(DBUS_IFACE),
            Some("CalendarsChanged"),
            Some(DBUS_PATH),
            None,
            gio::DBusSignalFlags::NONE,
            glib::clone!(
                #[weak(rename_to = this)]
                self,
                move |_c, _s, _p, _i, _sig, _params| {
                    glib::spawn_future_local(glib::clone!(
                        #[strong]
                        this,
                        async move { this.refresh_calendars().await }
                    ));
                }
            ),
        );
        // ExtensionStateChanged(name, state) — the finer per-ext run-state poke
        // (ready/exited/quarantined) the list-level poke can't carry.
        conn.signal_subscribe(
            Some(DBUS_NAME),
            Some(DBUS_IFACE),
            Some("ExtensionStateChanged"),
            Some(DBUS_PATH),
            None,
            gio::DBusSignalFlags::NONE,
            glib::clone!(
                #[weak(rename_to = this)]
                self,
                move |_c, _s, _p, _i, _sig, params| {
                    let name: String = params.child_value(0).get().unwrap_or_default();
                    let state: String = params.child_value(1).get().unwrap_or_default();
                    this.imp().ext_state.borrow_mut().insert(name, state);
                    glib::spawn_future_local(glib::clone!(
                        #[strong]
                        this,
                        async move { this.refresh_extensions().await }
                    ));
                }
            ),
        );

        // Initial liveness probe.
        glib::spawn_future_local(glib::clone!(
            #[strong(rename_to = this)]
            self,
            async move {
                let up = this.name_has_owner().await;
                this.set_daemon_up(up);
            }
        ));
    }

    async fn name_has_owner(&self) -> bool {
        let Some(conn) = self.connection() else {
            return false;
        };
        let params = (DBUS_NAME,).to_variant();
        match conn
            .call_future(
                Some(FDO_NAME),
                FDO_PATH,
                FDO_NAME,
                "NameHasOwner",
                Some(&params),
                None,
                gio::DBusCallFlags::NONE,
                CALL_TIMEOUT_MS,
            )
            .await
        {
            Ok(reply) => reply.child_value(0).get::<bool>().unwrap_or(false),
            Err(_) => false,
        }
    }

    /// The daemon is NOT D-Bus-activated — start the user service explicitly.
    pub fn start_daemon(&self) {
        let argv: [&OsStr; 4] = [
            OsStr::new("systemctl"),
            OsStr::new("--user"),
            OsStr::new("start"),
            OsStr::new("stoandl"),
        ];
        if let Err(e) = gio::Subprocess::newv(&argv, gio::SubprocessFlags::NONE) {
            eprintln!("stoandl: failed to launch daemon: {e}");
        }
    }

    // --- generic calls --------------------------------------------------------

    async fn raw_call(
        &self,
        method: &str,
        params: Option<&glib::Variant>,
        timeout_ms: i32,
    ) -> Result<glib::Variant, glib::Error> {
        let conn = self.connection().ok_or_else(|| {
            glib::Error::new(gio::IOErrorEnum::Failed, "no session bus connection")
        })?;
        conn.call_future(
            Some(DBUS_NAME),
            DBUS_PATH,
            DBUS_IFACE,
            method,
            params,
            None,
            gio::DBusCallFlags::NONE,
            timeout_ms,
        )
        .await
    }

    /// Call a `kind:tail` (`s`) method → parsed `Status`. A D-Bus error (daemon
    /// down / method missing) is surfaced as `Status{kind:"error"}` — never a
    /// thrown error, mirroring the Qt `callStatus`.
    pub async fn call_status(
        &self,
        method: &str,
        params: Option<glib::Variant>,
        timeout_ms: i32,
    ) -> Status {
        match self.raw_call(method, params.as_ref(), timeout_ms).await {
            Ok(reply) => parse_status(&reply.child_value(0).get::<String>().unwrap_or_default()),
            Err(e) => Status {
                kind: "error".into(),
                tail: e.message().to_string(),
                fields: Vec::new(),
            },
        }
    }

    /// Call an `as` method → the raw record strings (each is TAB-separated).
    pub async fn call_list(
        &self,
        method: &str,
        params: Option<glib::Variant>,
    ) -> Vec<String> {
        match self.raw_call(method, params.as_ref(), CALL_TIMEOUT_MS).await {
            Ok(reply) => reply.child_value(0).get::<Vec<String>>().unwrap_or_default(),
            Err(_) => Vec::new(),
        }
    }

    // --- Watch: list / connect / pair / forget -------------------------------

    /// Re-probe daemon liveness, fold in BluetoothStatus, re-fetch ListWatches,
    /// cache it and emit `watches-changed`. Call after any mutation (the signal
    /// is a best-effort poke; this re-fetch is authoritative).
    pub async fn refresh_watches(&self) {
        let up = self.name_has_owner().await;
        self.set_daemon_up(up);
        if !up {
            self.imp().watches.borrow_mut().clear();
            self.emit_watches_changed();
            return;
        }
        // `ok:off` => off; anything else (incl. an older daemon lacking the
        // method) => assume on, so we never flash a false "Bluetooth is off".
        let bt = self.call_status("BluetoothStatus", None, CALL_TIMEOUT_MS).await;
        self.set_bluetooth_on(!(bt.ok() && bt.tail == "off"));

        let rows = self.call_list("ListWatches", None).await;
        *self.imp().watches.borrow_mut() = parse_watches(&rows);
        self.emit_watches_changed();
    }

    pub async fn connect_watch(&self, name: &str) -> Status {
        self.call_status("Connect", Some((name,).to_variant()), CALL_TIMEOUT_MS).await
    }
    pub async fn pair(&self) -> Status {
        self.call_status("Pair", None, CALL_TIMEOUT_MS).await
    }
    pub async fn repair(&self, name: &str) -> Status {
        self.call_status("Repair", Some((name,).to_variant()), CALL_TIMEOUT_MS).await
    }
    pub async fn unpair(&self, name: &str) -> Status {
        self.call_status("Unpair", Some((name,).to_variant()), CALL_TIMEOUT_MS).await
    }
    pub async fn confirm_pairing(&self, accept: bool) -> Status {
        self.call_status("ConfirmPairing", Some((accept,).to_variant()), CALL_TIMEOUT_MS).await
    }

    /// FindWatch (`b`) — async, may linger daemon-side; result via `find-watch-result`.
    pub fn find_watch(&self) {
        glib::spawn_future_local(glib::clone!(
            #[strong(rename_to = this)]
            self,
            async move {
                let ok = match this.raw_call("FindWatch", None, FIND_TIMEOUT_MS).await {
                    Ok(reply) => reply.child_value(0).get::<bool>().unwrap_or(false),
                    Err(_) => false,
                };
                this.emit_by_name::<()>("find-watch-result", &[&ok]);
            }
        ));
    }

    // --- Watch details / rename / dev connection / diagnostics ---------------

    pub async fn watch_details(&self) -> Option<WatchDetails> {
        let s = self.call_status("WatchDetails", None, CALL_TIMEOUT_MS).await;
        parse_watch_details(&s)
    }
    pub async fn set_watch_nickname(&self, name: &str, nickname: &str) -> Status {
        self.call_status("SetWatchNickname", Some((name, nickname).to_variant()), CALL_TIMEOUT_MS).await
    }
    pub async fn start_dev_connection(&self) -> Status {
        self.call_status("StartDevConnection", None, CALL_TIMEOUT_MS).await
    }
    pub async fn stop_dev_connection(&self) -> Status {
        self.call_status("StopDevConnection", None, CALL_TIMEOUT_MS).await
    }
    /// DevConnectionStatus → true when `ok:active`.
    pub async fn dev_connection_active(&self) -> bool {
        let s = self.call_status("DevConnectionStatus", None, CALL_TIMEOUT_MS).await;
        s.ok() && s.tail == "active"
    }
    pub async fn take_screenshot(&self, path: &str) -> Status {
        self.call_status("TakeScreenshot", Some((path,).to_variant()), CALL_TIMEOUT_MS).await
    }
    pub async fn gather_logs(&self, path: &str) -> Status {
        self.call_status("GatherLogs", Some((path,).to_variant()), CALL_TIMEOUT_MS).await
    }
    pub async fn get_core_dump(&self, path: &str) -> Status {
        self.call_status("GetCoreDump", Some((path,).to_variant()), CALL_TIMEOUT_MS).await
    }
    pub async fn reset_into_recovery(&self) -> Status {
        self.call_status("ResetIntoRecovery", None, CALL_TIMEOUT_MS).await
    }
    pub async fn factory_reset(&self) -> Status {
        self.call_status("FactoryReset", None, CALL_TIMEOUT_MS).await
    }

    // --- Firmware -------------------------------------------------------------

    /// CheckFirmware → parsed info (None on non-ok). Returns the raw `Status`
    /// too so callers can distinguish uptodate/error from a bad reply.
    pub async fn check_firmware(&self) -> (Status, Option<FirmwareInfo>) {
        let s = self.call_status("CheckFirmware", None, CALL_TIMEOUT_MS).await;
        let info = parse_firmware_info(&s);
        (s, info)
    }
    pub async fn update_firmware(&self) -> Status {
        let s = self.call_status("UpdateFirmware", None, CALL_TIMEOUT_MS).await;
        if s.ok() {
            self.start_firmware_poll();
        }
        s
    }
    /// SideloadFirmware — `path` is an absolute daemon-side path to a `.pbz`.
    pub async fn sideload_firmware(&self, path: &str) -> Status {
        let s = self.call_status("SideloadFirmware", Some((path,).to_variant()), CALL_TIMEOUT_MS).await;
        if s.ok() {
            self.start_firmware_poll();
        }
        s
    }

    fn arm_firmware_timer(&self) {
        if self.imp().fw_poll.borrow().is_some() {
            return;
        }
        let id = glib::timeout_add_local(
            Duration::from_millis(FW_INTERVAL_MS),
            glib::clone!(
                #[weak(rename_to = this)]
                self,
                #[upgrade_or]
                glib::ControlFlow::Break,
                move || {
                    this.firmware_poll_tick();
                    glib::ControlFlow::Continue
                }
            ),
        );
        self.imp().fw_poll.replace(Some(id));
    }

    pub fn start_firmware_poll(&self) {
        self.imp().fw_elapsed.set(0);
        self.imp().fw_seen_activity.set(false);
        self.arm_firmware_timer();
    }

    pub fn stop_firmware_poll(&self) {
        if let Some(id) = self.imp().fw_poll.borrow_mut().take() {
            id.remove();
        }
    }

    fn firmware_poll_tick(&self) {
        let elapsed = self.imp().fw_elapsed.get() + FW_INTERVAL_MS as i32;
        self.imp().fw_elapsed.set(elapsed);
        if elapsed > FW_TIMEOUT_MS {
            self.stop_firmware_poll();
            self.signal_firmware_status("timeout", -1, "Flash timed out");
            return;
        }
        glib::spawn_future_local(glib::clone!(
            #[strong(rename_to = this)]
            self,
            async move {
                let s = this.call_status("FirmwareStatus", None, CALL_TIMEOUT_MS).await;
                let pct = if s.kind == "inprogress" {
                    parse_percent(&s.tail)
                } else {
                    -1
                };
                this.firmware_normalize(&s.kind, pct, &s.tail);
            }
        ));
    }

    /// Normalise a raw firmware phase (FirmwareStatus kind OR FirmwareProgress
    /// phase) to the terminal/progress `kind` the UI expects, then emit. Shared
    /// by the poll loop and the signal so both map reboot→success, post-activity
    /// notready→success, failed→failed identically, and ignore an idle/pre-
    /// activity notready poke when nothing is in flight.
    fn firmware_normalize(&self, phase: &str, percent: i32, detail: &str) {
        let imp = self.imp();
        if matches!(phase, "downloading" | "waiting" | "inprogress") {
            imp.fw_seen_activity.set(true);
            // Arm the watchdog even for a watch-triggered flash (GUI never called
            // start_firmware_poll). Don't reset seen_activity — we just set it.
            if imp.fw_poll.borrow().is_none() {
                imp.fw_elapsed.set(0);
                self.arm_firmware_timer();
            }
        }
        if phase == "reboot" || (phase == "notready" && imp.fw_seen_activity.get()) {
            self.stop_firmware_poll();
            self.signal_firmware_status("success", 100, "Watch is rebooting");
            return;
        }
        if phase == "failed" {
            self.stop_firmware_poll();
            self.signal_firmware_status("failed", -1, detail);
            return;
        }
        // An idle / pre-activity notready poke while nothing's in flight: don't flicker.
        if matches!(phase, "idle" | "notready")
            && imp.fw_poll.borrow().is_none()
            && !imp.fw_seen_activity.get()
        {
            return;
        }
        self.signal_firmware_status(phase, percent, detail);
    }

    // --- Language packs -------------------------------------------------------

    pub async fn list_languages(&self) -> Vec<LanguageRow> {
        let rows = self.call_list("ListLanguages", None).await;
        parse_languages(&rows)
    }
    pub async fn install_language(&self, query: &str) -> Status {
        let s = self.call_status("InstallLanguage", Some((query,).to_variant()), CALL_TIMEOUT_MS).await;
        if s.ok() {
            self.start_language_poll();
        }
        s
    }

    fn arm_language_timer(&self) {
        if self.imp().lang_poll.borrow().is_some() {
            return;
        }
        let id = glib::timeout_add_local(
            Duration::from_millis(LANG_INTERVAL_MS),
            glib::clone!(
                #[weak(rename_to = this)]
                self,
                #[upgrade_or]
                glib::ControlFlow::Break,
                move || {
                    this.language_poll_tick();
                    glib::ControlFlow::Continue
                }
            ),
        );
        self.imp().lang_poll.replace(Some(id));
    }

    pub fn start_language_poll(&self) {
        self.imp().lang_elapsed.set(0);
        self.imp().lang_seen_activity.set(false);
        self.imp().lang_first_poll.set(true);
        self.arm_language_timer();
    }

    pub fn stop_language_poll(&self) {
        if let Some(id) = self.imp().lang_poll.borrow_mut().take() {
            id.remove();
        }
    }

    fn language_poll_tick(&self) {
        let elapsed = self.imp().lang_elapsed.get() + LANG_INTERVAL_MS as i32;
        self.imp().lang_elapsed.set(elapsed);
        if elapsed > LANG_TIMEOUT_MS {
            self.stop_language_poll();
            self.signal_language_status("timeout", -1, "Install timed out");
            return;
        }
        glib::spawn_future_local(glib::clone!(
            #[strong(rename_to = this)]
            self,
            async move {
                let s = this.call_status("LanguageStatus", None, CALL_TIMEOUT_MS).await;
                // Skip one stale sticky terminal on the first poll (previous
                // install's snapshot). Poll-only guard — the signal is always live.
                if this.imp().lang_first_poll.get() {
                    this.imp().lang_first_poll.set(false);
                    if matches!(s.kind.as_str(), "done" | "idle" | "failed") {
                        return;
                    }
                }
                let pct = if s.kind == "installing" {
                    parse_percent(&s.tail)
                } else {
                    -1
                };
                this.language_normalize(&s.kind, pct, &s.tail);
            }
        ));
    }

    fn language_normalize(&self, phase: &str, percent: i32, detail: &str) {
        let imp = self.imp();
        if matches!(phase, "downloading" | "installing") {
            imp.lang_seen_activity.set(true);
        }
        if phase == "done" {
            self.stop_language_poll();
            self.signal_language_status("success", 100, detail);
            return;
        }
        if phase == "failed" {
            self.stop_language_poll();
            self.signal_language_status("failed", -1, detail);
            return;
        }
        if phase == "notready" && imp.lang_seen_activity.get() {
            self.stop_language_poll();
            self.signal_language_status("disconnected", -1, "Watch disconnected");
            return;
        }
        self.signal_language_status(phase, percent, detail);
    }

    // --- Health (read-only; period-aware) ------------------------------------

    pub async fn health_summary(&self, period_type: &str, offset: i32) -> Option<HealthSummary> {
        let s = self
            .call_status("GetHealthSummary", Some((period_type, offset).to_variant()), CALL_TIMEOUT_MS)
            .await;
        parse_health_summary(&s)
    }

    async fn health_series(&self, metric: &str, period_type: &str, offset: i32) -> Vec<String> {
        self.call_list("GetHealthSeries", Some((metric, period_type, offset).to_variant()))
            .await
    }

    pub async fn steps_bars(&self, period_type: &str, offset: i32) -> Vec<StepBar> {
        parse_step_bars(&self.health_series("steps", period_type, offset).await)
    }
    pub async fn sleep_timeline(&self, period_type: &str, offset: i32) -> Vec<SleepSegment> {
        parse_sleep_timeline(&self.health_series("sleep", period_type, offset).await)
    }
    pub async fn sleep_bars(&self, period_type: &str, offset: i32) -> Vec<SleepBar> {
        parse_sleep_bars(&self.health_series("sleep", period_type, offset).await)
    }
    pub async fn heart_samples(&self, period_type: &str, offset: i32) -> Vec<HeartSample> {
        parse_heart_samples(&self.health_series("heart", period_type, offset).await)
    }
    pub async fn heart_bars(&self, period_type: &str, offset: i32) -> Vec<HeartBar> {
        parse_heart_bars(&self.health_series("heart", period_type, offset).await)
    }

    /// The one Health mutation — trigger a health sync.
    pub async fn sync_health(&self) -> Status {
        self.call_status("SyncHealth", None, CALL_TIMEOUT_MS).await
    }

    // --- Apps & Faces + Extensions -------------------------------------------

    pub fn apps(&self) -> Vec<AppRow> {
        self.imp().apps.borrow().clone()
    }
    pub fn extensions(&self) -> Vec<ExtRow> {
        self.imp().extensions.borrow().clone()
    }

    fn emit_apps_changed(&self) {
        self.emit_by_name::<()>("apps-changed", &[]);
    }
    fn emit_extensions_changed(&self) {
        self.emit_by_name::<()>("extensions-changed", &[]);
    }

    pub fn connect_apps_changed<F: Fn(&Self) + 'static>(&self, f: F) {
        self.connect_closure(
            "apps-changed",
            false,
            glib::closure_local!(move |c: StoandlClient| f(&c)),
        );
    }
    pub fn connect_extensions_changed<F: Fn(&Self) + 'static>(&self, f: F) {
        self.connect_closure(
            "extensions-changed",
            false,
            glib::closure_local!(move |c: StoandlClient| f(&c)),
        );
    }

    /// Re-fetch ListApps, cache it, emit `apps-changed` (call after any mutation).
    pub async fn refresh_apps(&self) {
        let up = self.name_has_owner().await;
        self.set_daemon_up(up);
        let apps = if up {
            parse_apps(&self.call_list("ListApps", None).await)
        } else {
            Vec::new()
        };
        *self.imp().apps.borrow_mut() = apps;
        self.emit_apps_changed();
    }

    /// GetAppIcon(uuid) → a local file path (or None). Fetched lazily per row and
    /// cached, so repeated locker rebuilds don't re-issue the D-Bus call.
    pub async fn app_icon(&self, uuid: &str) -> Option<String> {
        if uuid.is_empty() {
            return None;
        }
        if let Some(hit) = self.imp().icon_cache.borrow().get(uuid) {
            return hit.clone();
        }
        let s = self.call_status("GetAppIcon", Some((uuid,).to_variant()), CALL_TIMEOUT_MS).await;
        let path = if s.ok() && !s.tail.is_empty() { Some(s.tail) } else { None };
        self.imp().icon_cache.borrow_mut().insert(uuid.to_string(), path.clone());
        path
    }

    pub async fn launch_app(&self, id: &str) -> Status {
        self.call_status("LaunchApp", Some((id,).to_variant()), CALL_TIMEOUT_MS).await
    }
    pub async fn remove_app(&self, id: &str) -> Status {
        self.call_status("RemoveApp", Some((id,).to_variant()), CALL_TIMEOUT_MS).await
    }
    pub async fn sideload_app(&self, path: &str) -> Status {
        self.call_status("SideloadApp", Some((path,).to_variant()), CALL_TIMEOUT_MS).await
    }

    /// OpenConfig — the reply may be a bare URL, empty (none), or a status.
    /// Returns (kind, url, msg); the page opens the URL.
    pub async fn open_config(&self, id: &str) -> (String, String, String) {
        match self.raw_call("OpenConfig", Some(&(id,).to_variant()), CALL_TIMEOUT_MS).await {
            Ok(reply) => {
                parse_open_config(&reply.child_value(0).get::<String>().unwrap_or_default())
            }
            Err(e) => ("error".into(), String::new(), e.message().to_string()),
        }
    }

    /// Re-fetch ExtList (merging the run-state overrides), prune stale overrides,
    /// cache it, emit `extensions-changed`.
    pub async fn refresh_extensions(&self) {
        let up = self.name_has_owner().await;
        self.set_daemon_up(up);
        let exts = if up {
            let rows = self.call_list("ExtList", None).await;
            let parsed = parse_ext_list(&rows, &self.imp().ext_state.borrow());
            // Drop overrides for extensions ExtList no longer reports.
            let seen: std::collections::HashSet<&str> =
                parsed.iter().map(|e| e.name.as_str()).collect();
            self.imp().ext_state.borrow_mut().retain(|k, _| seen.contains(k.as_str()));
            parsed
        } else {
            Vec::new()
        };
        *self.imp().extensions.borrow_mut() = exts;
        self.emit_extensions_changed();
    }

    pub async fn ext_enable(&self, name: &str) -> Status {
        self.call_status("ExtEnable", Some((name,).to_variant()), CALL_TIMEOUT_MS).await
    }
    pub async fn ext_disable(&self, name: &str) -> Status {
        self.call_status("ExtDisable", Some((name,).to_variant()), CALL_TIMEOUT_MS).await
    }
    pub async fn ext_restart(&self, name: &str) -> Status {
        self.call_status("ExtRestart", Some((name,).to_variant()), CALL_TIMEOUT_MS).await
    }
    pub async fn ext_uninstall(&self, name: &str, keep_config: bool) -> Status {
        self.call_status("ExtUninstall", Some((name, keep_config).to_variant()), CALL_TIMEOUT_MS).await
    }
    pub async fn ext_install(&self, path: &str) -> Status {
        self.call_status("ExtInstall", Some((path,).to_variant()), CALL_TIMEOUT_MS).await
    }

    /// ExtOpenConfig(name) → (kind, url, msg); the page opens the URL.
    pub async fn ext_open_config(&self, name: &str) -> (String, String, String) {
        let s = self.call_status("ExtOpenConfig", Some((name,).to_variant()), CALL_TIMEOUT_MS).await;
        if s.ok() {
            ("ok".into(), s.tail, String::new())
        } else {
            (s.kind, String::new(), s.tail)
        }
    }

    pub async fn ext_config_schema(&self, name: &str) -> Vec<ExtField> {
        let s = self.call_status("ExtConfigSchema", Some((name,).to_variant()), CALL_TIMEOUT_MS).await;
        if s.ok() {
            parse_ext_schema(&s.tail)
        } else {
            Vec::new()
        }
    }

    pub async fn ext_get_config(&self, name: &str) -> serde_json::Map<String, serde_json::Value> {
        let s = self.call_status("ExtGetConfig", Some((name,).to_variant()), CALL_TIMEOUT_MS).await;
        if s.ok() {
            serde_json::from_str::<serde_json::Value>(&s.tail)
                .ok()
                .and_then(|v| v.as_object().cloned())
                .unwrap_or_default()
        } else {
            serde_json::Map::new()
        }
    }

    pub async fn ext_set_config(
        &self,
        name: &str,
        values: serde_json::Map<String, serde_json::Value>,
    ) -> Status {
        let json = serde_json::Value::Object(values).to_string();
        self.call_status("ExtSetConfig", Some((name, json.as_str()).to_variant()), CALL_TIMEOUT_MS)
            .await
    }

    // --- Notifications + sync status -----------------------------------------

    pub async fn get_sync_status(&self) -> Vec<SyncStatus> {
        parse_sync_status(&self.call_list("GetSyncStatus", None).await)
    }
    pub async fn set_sync_enabled(&self, service: &str, enabled: bool) -> Status {
        self.call_status("SetSyncEnabled", Some((service, enabled).to_variant()), CALL_TIMEOUT_MS).await
    }

    pub async fn notif_list(&self) -> Vec<NotifApp> {
        parse_notif_list(&self.call_list("NotifList", None).await)
    }
    pub async fn notif_set_mute(&self, name: &str, spec: &str) -> Status {
        self.call_status("NotifSetMute", Some((name, spec).to_variant()), CALL_TIMEOUT_MS).await
    }
    pub async fn notif_set_mute_all(&self, spec: &str) -> Status {
        self.call_status("NotifSetMuteAll", Some((spec,).to_variant()), CALL_TIMEOUT_MS).await
    }
    pub async fn notif_set_style(&self, name: &str, color: &str, icon: &str, vibe: &str) -> Status {
        self.call_status("NotifSetStyle", Some((name, color, icon, vibe).to_variant()), CALL_TIMEOUT_MS).await
    }
    pub async fn notif_list_filters(&self) -> Vec<NotifFilter> {
        parse_notif_filters(&self.call_list("NotifListFilters", None).await)
    }
    pub async fn notif_add_filter(&self, pattern: &str, action: &str) -> Status {
        self.call_status("NotifAddFilter", Some((pattern, action).to_variant()), CALL_TIMEOUT_MS).await
    }
    pub async fn notif_remove_filter(&self, pattern: &str) -> Status {
        self.call_status("NotifRemoveFilter", Some((pattern,).to_variant()), CALL_TIMEOUT_MS).await
    }

    // --- Settings: sync services / watch prefs / config / calendars ----------

    pub async fn sync_weather(&self) -> Status {
        self.call_status("SyncWeather", None, CALL_TIMEOUT_MS).await
    }
    pub async fn sync_calendar(&self) -> Status {
        self.call_status("SyncCalendar", None, CALL_TIMEOUT_MS).await
    }

    pub async fn list_watch_prefs(&self) -> Vec<WatchPref> {
        parse_watch_prefs(&self.call_list("ListWatchPrefs", None).await)
    }
    pub async fn set_watch_pref(&self, id: &str, value: &str) -> Status {
        self.call_status("SetWatchPref", Some((id, value).to_variant()), CALL_TIMEOUT_MS).await
    }

    pub async fn config_schema(&self) -> Vec<ConfigField> {
        parse_config_schema(&self.call_list("GetConfigSchema", None).await)
    }
    pub async fn get_config(&self) -> Vec<(String, String)> {
        parse_config_values(&self.call_list("GetConfig", None).await)
    }
    pub async fn set_config(&self, key: &str, value: &str) -> Status {
        self.call_status("SetConfig", Some((key, value).to_variant()), CALL_TIMEOUT_MS).await
    }

    // Calendars: sources (CalDAV/iCal) + their discovered calendars.
    pub fn calendars(&self) -> Vec<Calendar> {
        self.imp().calendars.borrow().clone()
    }
    pub fn connect_calendars_changed<F: Fn(&Self) + 'static>(&self, f: F) {
        self.connect_closure(
            "calendars-changed",
            false,
            glib::closure_local!(move |c: StoandlClient| f(&c)),
        );
    }
    pub async fn refresh_calendars(&self) {
        let up = self.name_has_owner().await;
        self.set_daemon_up(up);
        let cals = if up {
            parse_calendars(&self.call_list("ListCalendars", None).await)
        } else {
            Vec::new()
        };
        *self.imp().calendars.borrow_mut() = cals;
        self.emit_by_name::<()>("calendars-changed", &[]);
    }
    pub async fn set_calendar_enabled(&self, id: &str, enabled: bool) -> Status {
        self.call_status("SetCalendarEnabled", Some((id, enabled).to_variant()), CALL_TIMEOUT_MS).await
    }
    pub async fn list_calendar_sources(&self) -> Vec<CalendarSource> {
        parse_calendar_sources(&self.call_list("ListCalendarSources", None).await)
    }
    pub async fn add_calendar_source(
        &self,
        source_type: &str,
        url: &str,
        username: &str,
        password: &str,
    ) -> Status {
        self.call_status(
            "AddCalendarSource",
            Some((source_type, url, username, password).to_variant()),
            CALL_TIMEOUT_MS,
        )
        .await
    }
    pub async fn update_calendar_source(
        &self,
        id: &str,
        url: &str,
        username: &str,
        password: &str,
    ) -> Status {
        self.call_status(
            "UpdateCalendarSource",
            Some((id, url, username, password).to_variant()),
            CALL_TIMEOUT_MS,
        )
        .await
    }
    pub async fn remove_calendar_source(&self, id: &str) -> Status {
        self.call_status("RemoveCalendarSource", Some((id,).to_variant()), CALL_TIMEOUT_MS).await
    }

    // --- Watch poll (20 s safety-net + BluetoothStatus carrier) --------------

    pub fn start_watch_poll(&self) {
        if self.imp().watch_poll.borrow().is_none() {
            let id = glib::timeout_add_seconds_local(
                WATCH_INTERVAL_S,
                glib::clone!(
                    #[weak(rename_to = this)]
                    self,
                    #[upgrade_or]
                    glib::ControlFlow::Break,
                    move || {
                        glib::spawn_future_local(glib::clone!(
                            #[strong]
                            this,
                            async move { this.refresh_watches().await }
                        ));
                        glib::ControlFlow::Continue
                    }
                ),
            );
            self.imp().watch_poll.replace(Some(id));
        }
        glib::spawn_future_local(glib::clone!(
            #[strong(rename_to = this)]
            self,
            async move { this.refresh_watches().await }
        ));
    }

    pub fn stop_watch_poll(&self) {
        if let Some(id) = self.imp().watch_poll.borrow_mut().take() {
            id.remove();
        }
    }

    // --- Pair poll (1.5 s, 145 s ceiling) ------------------------------------

    pub fn start_pair_poll(&self) {
        self.imp().pair_elapsed.set(0);
        if self.imp().pair_poll.borrow().is_some() {
            return;
        }
        let id = glib::timeout_add_local(
            Duration::from_millis(PAIR_INTERVAL_MS),
            glib::clone!(
                #[weak(rename_to = this)]
                self,
                #[upgrade_or]
                glib::ControlFlow::Break,
                move || {
                    this.pair_poll_tick();
                    glib::ControlFlow::Continue
                }
            ),
        );
        self.imp().pair_poll.replace(Some(id));
    }

    pub fn stop_pair_poll(&self) {
        if let Some(id) = self.imp().pair_poll.borrow_mut().take() {
            id.remove();
        }
    }

    fn pair_poll_tick(&self) {
        let elapsed = self.imp().pair_elapsed.get() + PAIR_INTERVAL_MS as i32;
        self.imp().pair_elapsed.set(elapsed);
        if elapsed > PAIR_TIMEOUT_MS {
            self.stop_pair_poll();
            self.emit_pair_status("timeout", "Pairing timed out");
            return;
        }
        glib::spawn_future_local(glib::clone!(
            #[strong(rename_to = this)]
            self,
            async move {
                let s = this.call_status("PairStatus", None, CALL_TIMEOUT_MS).await;
                this.emit_pair_status(&s.kind, &s.tail);
                if matches!(s.kind.as_str(), "ok" | "error" | "timeout") {
                    this.stop_pair_poll();
                }
            }
        ));
    }
}
