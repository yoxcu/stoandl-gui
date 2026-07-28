//! The Watch tab (`StoandlWatchPage`) — GTK4/libadwaita port of `qml/WatchPage.qml`
//! + `qml/WatchDetailsDialog.qml`. The overview: header actions (pair / ring /
//! sync), a Bluetooth-off banner, a firmware update/flash section, the active-
//! watch hero, and the known-watches list with inline connect/forget. Pairing is
//! an `Adw.Dialog`; forget is an `Adw.AlertDialog`. All parsing is in the client.

use std::cell::{Cell, OnceCell, RefCell};
use std::time::{SystemTime, UNIX_EPOCH};

use adw::prelude::*;
use adw::subclass::prelude::*;
use gtk::{gio, glib, CompositeTemplate};

use super::esc;
use crate::dbus::{FirmwareInfo, LanguageRow, StoandlClient, WatchDetails, WatchRow};
use crate::window::StoandlWindow;

/// A daemon-side temp path for a diagnostics artefact (screenshot / logs / core
/// dump). The GUI is co-located with the daemon, so a local tmp path is valid.
fn temp_path(prefix: &str, ext: &str) -> String {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    glib::tmp_dir()
        .join(format!("{prefix}-{ts}.{ext}"))
        .to_string_lossy()
        .into_owned()
}

/// `classic`/`ble` token (ListWatches) → human label. NOT applied to the
/// WatchDetails transport, which is already a human label from the daemon.
fn transport_label(t: &str) -> String {
    match t {
        "classic" => "Bluetooth Classic".into(),
        "ble" => "Bluetooth LE".into(),
        other => other.into(),
    }
}

/// Diagnostics for the headless smoke test (no-op unless run under
/// `run-with-mock-gtk.sh --headless`, which sets `STOANDL_SMOKE_MS`). Proves the
/// D-Bus→parse→render pipeline populated, not merely that nothing crashed.
fn dbg_smoke(msg: &str) {
    if std::env::var_os("STOANDL_SMOKE_MS").is_some() {
        eprintln!("stoandl-smoke: {msg}");
    }
}

fn fw_phase_label(phase: &str, percent: i32) -> String {
    match phase {
        "downloading" => "Downloading firmware…".into(),
        "waiting" => "Preparing…".into(),
        "inprogress" => {
            if percent >= 0 {
                format!("Flashing… {percent}%")
            } else {
                "Flashing…".into()
            }
        }
        "notready" => "Waiting for the watch…".into(),
        _ => "Working…".into(),
    }
}

fn lang_phase_label(phase: &str, percent: i32) -> String {
    match phase {
        "downloading" => "Downloading language pack…".into(),
        "installing" | "inprogress" => {
            if percent >= 0 {
                format!("Installing… {percent}%")
            } else {
                "Installing…".into()
            }
        }
        _ => "Installing…".into(),
    }
}

mod imp {
    use super::*;

    #[derive(CompositeTemplate, Default)]
    #[template(resource = "/de/yoxcu/stoandl/gui/ui/watch.ui")]
    pub struct StoandlWatchPage {
        #[template_child]
        pub nav_view: TemplateChild<adw::NavigationView>,
        #[template_child]
        pub pair_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub ring_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub sync_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub bt_banner: TemplateChild<adw::Banner>,
        #[template_child]
        pub content_stack: TemplateChild<gtk::Stack>,
        #[template_child]
        pub empty_pair_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub fw_progress: TemplateChild<gtk::Box>,
        #[template_child]
        pub fw_phase_label: TemplateChild<gtk::Label>,
        #[template_child]
        pub fw_progressbar: TemplateChild<gtk::ProgressBar>,
        #[template_child]
        pub fw_update_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub fw_update_row: TemplateChild<adw::ActionRow>,
        #[template_child]
        pub whatsnew_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub update_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub hero_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub battery_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub battery_row: TemplateChild<adw::ActionRow>,
        #[template_child]
        pub known_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub view_switcher: TemplateChild<adw::ViewSwitcher>,
        #[template_child]
        pub switcher_bar: TemplateChild<adw::ViewSwitcherBar>,

        pub client: OnceCell<StoandlClient>,

        // Firmware banner/flash state (mirrors the QML page properties).
        pub fw_info: RefCell<Option<FirmwareInfo>>,
        pub fw_phase: RefCell<String>, // "" = idle
        pub fw_percent: Cell<i32>,

        // Dynamically added rows (removed on rebuild).
        pub hero_rows: RefCell<Vec<gtk::Widget>>,
        pub known_rows: RefCell<Vec<gtk::Widget>>,

        // The live pairing dialog (Some while open), so pair-status can update it.
        pub pair_ui: RefCell<Option<PairUi>>,

        // The language PreferencesGroup while the language page is open, so a
        // language-status success can reload it in place. Plus its dynamic rows.
        pub lang_group: RefCell<Option<adw::PreferencesGroup>>,
        pub lang_rows: RefCell<Vec<gtk::Widget>>,
        // Live install progress on the language page: an indeterminate bar (pulses
        // until a % arrives), shown only while an install is in flight.
        pub lang_progress_group: RefCell<Option<adw::PreferencesGroup>>,
        pub lang_progressbar: RefCell<Option<gtk::ProgressBar>>,
        pub lang_busy: Cell<bool>,
        pub lang_percent: Cell<i32>,
        // The details page's "Language" row (while a details page is on the stack),
        // so an install success updates its subtitle live too (not just the list).
        pub details_lang_row: RefCell<Option<adw::ActionRow>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for StoandlWatchPage {
        const NAME: &'static str = "StoandlWatchPage";
        type Type = super::StoandlWatchPage;
        type ParentType = adw::BreakpointBin;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(obj: &glib::subclass::InitializingObject<Self>) {
            obj.init_template();
        }
    }

    impl ObjectImpl for StoandlWatchPage {}
    impl WidgetImpl for StoandlWatchPage {}
    impl BreakpointBinImpl for StoandlWatchPage {}

    /// Widgets of the live pairing dialog we need to update as pair-status arrives.
    #[derive(Clone)]
    pub struct PairUi {
        pub dialog: adw::Dialog,
        pub prompt: gtk::Label,
        pub code: gtk::Label,
        pub spinner: adw::Spinner,
        pub error_icon: gtk::Image,
        pub status: gtk::Label,
        pub confirm_box: gtk::Box,
    }
}

pub use imp::PairUi;

glib::wrapper! {
    pub struct StoandlWatchPage(ObjectSubclass<imp::StoandlWatchPage>)
        @extends adw::BreakpointBin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl Default for StoandlWatchPage {
    fn default() -> Self {
        Self::new()
    }
}

impl StoandlWatchPage {
    pub fn new() -> Self {
        glib::Object::new()
    }

    /// Bind this page's in-header view switcher + narrow bottom bar to the shell stack.
    pub fn bind_switcher(&self, stack: &adw::ViewStack) {
        self.imp().view_switcher.set_stack(Some(stack));
        self.imp().switcher_bar.set_stack(Some(stack));
    }

    fn client(&self) -> StoandlClient {
        self.imp().client.get().expect("client bound").clone()
    }

    /// App-wide toast via the window's Adw.ToastOverlay.
    fn toast(&self, msg: &str) {
        if let Some(win) = self.root().and_downcast::<StoandlWindow>() {
            win.toast(msg);
        }
    }

    /// Store the client, wire every handler + signal, and kick the initial load.
    pub fn bind_client(&self, client: &StoandlClient) {
        self.imp().client.set(client.clone()).ok();

        // --- header + empty-state actions ------------------------------------
        self.imp().pair_button.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.open_pair_dialog()
        ));
        self.imp().empty_pair_button.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.open_pair_dialog()
        ));
        self.imp().ring_button.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.client().find_watch()
        ));
        self.imp().battery_row.connect_activated(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.open_battery()
        ));
        self.imp().sync_button.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| {
                let client = page.client();
                glib::spawn_future_local(glib::clone!(
                    #[weak]
                    page,
                    #[strong]
                    client,
                    async move {
                        client.refresh_watches().await;
                        page.refresh_firmware().await;
                        page.toast("Refreshed");
                    }
                ));
            }
        ));

        // --- firmware update actions -----------------------------------------
        self.imp().whatsnew_button.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| {
                let url = page
                    .imp()
                    .fw_info
                    .borrow()
                    .as_ref()
                    .map(|i| i.changelog_url.clone())
                    .unwrap_or_default();
                if url.is_empty() {
                    page.toast("No changelog available");
                } else {
                    let launcher = gtk::UriLauncher::new(&url);
                    let parent = page.root().and_downcast::<gtk::Window>();
                    launcher.launch(parent.as_ref(), gio::Cancellable::NONE, |_| {});
                }
            }
        ));
        self.imp().update_button.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| {
                let client = page.client();
                glib::spawn_future_local(glib::clone!(
                    #[weak]
                    page,
                    #[strong]
                    client,
                    async move {
                        let s = client.update_firmware().await;
                        if s.ok() {
                            page.toast("Firmware flash started…");
                        } else if s.kind == "uptodate" {
                            page.toast("Already up to date");
                        } else {
                            let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                            page.toast(&format!("Firmware: {m}"));
                        }
                    }
                ));
            }
        ));

        // --- client signals (augment polling) --------------------------------
        client.connect_watches_changed(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.rebuild_watches()
        ));
        client.connect_firmware_status(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_, kind, pct, detail| page.handle_firmware_status(kind, pct, detail)
        ));
        client.connect_find_watch_result(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_, ok| page.toast(if ok { "Ringing watch…" } else { "No watch ready to ring" })
        ));
        client.connect_pair_status(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_, kind, msg| page.handle_pair_status(kind, msg)
        ));
        client.connect_language_status(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_, kind, pct, detail| page.handle_language_status(kind, pct, detail)
        ));

        // daemon-up / bluetooth-on drive chrome + a firmware re-check on connect.
        client.connect_notify_local(
            Some("daemon-up"),
            glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |c, _| {
                    page.update_chrome();
                    if c.daemon_up() {
                        glib::spawn_future_local(glib::clone!(
                            #[weak]
                            page,
                            async move { page.refresh_firmware().await }
                        ));
                    }
                }
            ),
        );
        client.connect_notify_local(
            Some("bluetooth-on"),
            glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_, _| page.update_chrome()
            ),
        );

        // --- initial load -----------------------------------------------------
        self.update_chrome();
        client.start_watch_poll(); // immediate refresh → watches-changed → rebuild
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            async move { page.refresh_firmware().await }
        ));
    }

    // --- chrome: banner + action sensitivity ---------------------------------

    fn update_chrome(&self) {
        let c = self.client();
        let up = c.daemon_up();
        let bt = c.bluetooth_on();
        let imp = self.imp();
        imp.bt_banner.set_revealed(up && !bt);
        imp.pair_button.set_sensitive(up && bt);
        imp.empty_pair_button.set_sensitive(up && bt);
        imp.sync_button.set_sensitive(up);
        imp.ring_button.set_sensitive(up && c.connected_watch().is_some());
    }

    // --- watches: rebuild hero + known list ----------------------------------

    fn rebuild_watches(&self) {
        let c = self.client();
        let watches = c.watches();
        let bt = c.bluetooth_on();
        let imp = self.imp();

        // Empty state only when Bluetooth is on and no watches are known
        // (BT-off shows the banner instead, per the QML).
        let show_empty = bt && watches.is_empty();
        imp.content_stack
            .set_visible_child_name(if show_empty { "empty" } else { "content" });

        self.rebuild_hero(&watches);
        self.rebuild_known(&watches);
        // Battery insights entry: only meaningful with a connected watch.
        imp.battery_group
            .set_visible(watches.iter().any(|w| w.connected));
        self.update_chrome(); // ring button depends on connected_watch

        dbg_smoke(&format!(
            "watch rebuild: {} known, connected={:?}, bt_on={}, stack={}",
            watches.len(),
            c.connected_watch().map(|w| w.name),
            bt,
            if show_empty { "empty" } else { "content" },
        ));
    }

    fn clear_rows(group: &adw::PreferencesGroup, rows: &RefCell<Vec<gtk::Widget>>) {
        for w in rows.borrow_mut().drain(..) {
            group.remove(&w);
        }
    }

    fn rebuild_hero(&self, watches: &[WatchRow]) {
        let imp = self.imp();
        Self::clear_rows(&imp.hero_group, &imp.hero_rows);

        let Some(w) = watches.iter().find(|w| w.connected) else {
            imp.hero_group.set_visible(false);
            return;
        };
        imp.hero_group.set_visible(true);

        let subtitle = if w.transport.is_empty() {
            "Connected".to_string()
        } else {
            format!("Connected · {}", transport_label(&w.transport))
        };
        let row = adw::ActionRow::builder()
            .title(&esc(&w.name))
            .subtitle(&esc(&subtitle))
            .activatable(true)
            .build();

        let icon = gtk::Image::from_icon_name("preferences-system-time-symbolic");
        icon.set_pixel_size(32);
        row.add_prefix(&icon);

        if !w.battery.is_empty() {
            let batt = gtk::Label::new(Some(&format!("{}%", w.battery)));
            batt.add_css_class("dim-label");
            row.add_suffix(&batt);
        }
        let chevron = gtk::Image::from_icon_name("go-next-symbolic");
        chevron.add_css_class("dim-label");
        row.add_suffix(&chevron);

        row.connect_activated(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.open_details()
        ));

        imp.hero_group.add(&row);
        imp.hero_rows.borrow_mut().push(row.upcast());
    }

    fn rebuild_known(&self, watches: &[WatchRow]) {
        let imp = self.imp();
        Self::clear_rows(&imp.known_group, &imp.known_rows);

        imp.known_group.set_visible(!watches.is_empty());

        for w in watches {
            // "connecting" is the transient state between disconnected and connected —
            // surface it (no Connect button, a "connecting" chip) rather than showing a
            // connecting watch as plain disconnected.
            let connecting = w.state == "connecting";
            let subtitle = if w.connected {
                let mut s = transport_label(&w.transport);
                if !w.battery.is_empty() {
                    s.push_str(&format!(" · {}%", w.battery));
                }
                s
            } else if connecting {
                "Connecting…".to_string()
            } else {
                "disconnected".to_string()
            };
            let row = adw::ActionRow::builder()
                .title(&esc(&w.name))
                .subtitle(&esc(&subtitle))
                .activatable(!w.connected && !connecting)
                .build();

            let icon = gtk::Image::from_icon_name("preferences-system-time-symbolic");
            if !w.connected && !connecting {
                icon.add_css_class("dim-label");
            }
            row.add_prefix(&icon);

            if w.connected {
                let pill = gtk::Label::new(Some("active"));
                pill.set_valign(gtk::Align::Center);
                pill.add_css_class("status-chip");
                pill.add_css_class("success");
                row.add_suffix(&pill);
            } else if connecting {
                // Accent (neutral emphasis), not warning/amber — "connecting" is a
                // benign, self-resolving transition, not a problem needing attention.
                let pill = gtk::Label::new(Some("connecting"));
                pill.set_valign(gtk::Align::Center);
                pill.add_css_class("status-chip");
                pill.add_css_class("accent");
                row.add_suffix(&pill);
            } else {
                let connect = gtk::Button::with_label("Connect");
                connect.set_valign(gtk::Align::Center);
                let name = w.name.clone();
                connect.connect_clicked(glib::clone!(
                    #[weak(rename_to = page)]
                    self,
                    move |_| page.connect_to(&name)
                ));
                row.add_suffix(&connect);
            }

            let forget = gtk::Button::from_icon_name("user-trash-symbolic");
            forget.set_valign(gtk::Align::Center);
            forget.add_css_class("flat");
            forget.set_tooltip_text(Some("Forget watch"));
            let name = w.name.clone();
            forget.connect_clicked(glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_| page.open_forget_dialog(&name)
            ));
            row.add_suffix(&forget);

            if !w.connected && !connecting {
                let name = w.name.clone();
                row.connect_activated(glib::clone!(
                    #[weak(rename_to = page)]
                    self,
                    move |_| page.connect_to(&name)
                ));
            }

            imp.known_group.add(&row);
            imp.known_rows.borrow_mut().push(row.upcast());
        }
    }

    fn connect_to(&self, name: &str) {
        let client = self.client();
        let name = name.to_string();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let s = client.connect_watch(&name).await;
                if !s.ok() {
                    let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                    page.toast(&format!("Connect failed: {m}"));
                }
                client.refresh_watches().await; // re-fetch after mutation
            }
        ));
    }

    // --- firmware -------------------------------------------------------------

    /// CheckFirmware → update the "Firmware update" section.
    async fn refresh_firmware(&self) {
        let c = self.client();
        if !c.daemon_up() || self.fw_busy() {
            return; // a flash is in flight — its terminal status is authoritative
        }
        let (_status, info) = c.check_firmware().await;
        // A flash may have completed while we awaited CheckFirmware; its terminal
        // firmware-status already cleared fw_info/phase — don't resurrect the
        // "update available" card (the async client made this interleave possible
        // where the Qt synchronous call could not).
        if self.fw_busy() {
            return;
        }
        self.imp().fw_info.replace(info);
        self.update_fw_ui();
    }

    fn fw_busy(&self) -> bool {
        !self.imp().fw_phase.borrow().is_empty()
    }

    fn handle_firmware_status(&self, kind: &str, percent: i32, detail: &str) {
        match kind {
            "success" => {
                self.toast("Firmware flashed — watch is rebooting");
                self.imp().fw_phase.replace(String::new());
                self.imp().fw_percent.set(-1);
                self.imp().fw_info.replace(None);
            }
            "failed" => {
                self.toast(&format!("Flash failed: {detail}"));
                self.imp().fw_phase.replace(String::new());
                self.imp().fw_percent.set(-1);
            }
            "timeout" => {
                self.toast("Flash timed out");
                self.imp().fw_phase.replace(String::new());
                self.imp().fw_percent.set(-1);
            }
            // Idle is terminal (defence-in-depth): a stray idle/notready frame after a
            // flash must clear the banner, not re-show "Working…". The client normalises
            // most of these away; this catches any that slip through.
            "idle" | "notready" => {
                self.imp().fw_phase.replace(String::new());
                self.imp().fw_percent.set(-1);
            }
            _ => {
                self.imp().fw_phase.replace(kind.to_string());
                self.imp().fw_percent.set(percent);
            }
        }
        self.update_fw_ui();
    }

    fn update_fw_ui(&self) {
        let imp = self.imp();
        let busy = self.fw_busy();

        imp.fw_progress.set_visible(busy);
        if busy {
            let phase = imp.fw_phase.borrow().clone();
            let pct = imp.fw_percent.get();
            imp.fw_phase_label.set_label(&fw_phase_label(&phase, pct));
            if pct < 0 {
                imp.fw_progressbar.pulse();
            } else {
                imp.fw_progressbar.set_fraction(pct as f64 / 100.0);
            }
        }

        // Update banner only when idle and an update is actually available.
        let info = imp.fw_info.borrow();
        let show_update = !busy && info.as_ref().is_some_and(|i| i.update_available);
        imp.fw_update_group.set_visible(show_update);
        if let (true, Some(i)) = (show_update, info.as_ref()) {
            imp.fw_update_row
                .set_title(&format!("PebbleOS {} available", i.latest));
            imp.whatsnew_button.set_sensitive(!i.changelog_url.is_empty());
        }
        dbg_smoke(&format!(
            "fw ui: busy={busy}, update_available={}, latest={:?}",
            info.as_ref().is_some_and(|i| i.update_available),
            info.as_ref().map(|i| i.latest.clone()),
        ));
    }

    // --- pairing dialog -------------------------------------------------------

    fn open_pair_dialog(&self) {
        let prompt = gtk::Label::builder()
            .wrap(true)
            .xalign(0.0)
            .label("Put the watch in pairing mode.")
            .build();
        let code = gtk::Label::builder().halign(gtk::Align::Center).visible(false).build();
        code.add_css_class("pairing-code");
        // Adw.Spinner (libadwaita ≥1.6) — auto-animates; constrain its size so it
        // does not balloon to fill the status row.
        let spinner = adw::Spinner::new();
        spinner.set_size_request(24, 24);
        spinner.set_valign(gtk::Align::Center);
        spinner.set_halign(gtk::Align::Center);
        let error_icon = gtk::Image::from_icon_name("dialog-error-symbolic");
        error_icon.set_visible(false);
        let status = gtk::Label::builder()
            .wrap(true)
            .xalign(0.0)
            .hexpand(true)
            .label("Opening pairing window…")
            .build();

        let status_row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        status_row.append(&spinner);
        status_row.append(&error_icon);
        status_row.append(&status);

        // Numeric-comparison Accept/Decline (visible only in the confirm phase).
        let confirm_box = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        confirm_box.set_visible(false);
        let decline = gtk::Button::with_label("Decline");
        let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        spacer.set_hexpand(true);
        let accept = gtk::Button::with_label("Accept");
        accept.add_css_class("suggested-action");
        confirm_box.append(&decline);
        confirm_box.append(&spacer);
        confirm_box.append(&accept);

        let content = gtk::Box::new(gtk::Orientation::Vertical, 12);
        content.set_margin_top(18);
        content.set_margin_bottom(18);
        content.set_margin_start(18);
        content.set_margin_end(18);
        content.append(&prompt);
        content.append(&code);
        content.append(&status_row);
        content.append(&confirm_box);

        let header = adw::HeaderBar::new();
        let tv = adw::ToolbarView::new();
        tv.add_top_bar(&header);
        tv.set_content(Some(&content));

        let dialog = adw::Dialog::new();
        dialog.set_title("Pair watch");
        dialog.set_content_width(400);
        dialog.set_child(Some(&tv));

        decline.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.answer_pairing(false)
        ));
        accept.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.answer_pairing(true)
        ));

        // Stop the poll + drop our handle when the dialog closes.
        dialog.connect_closed(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| {
                page.client().stop_pair_poll();
                page.imp().pair_ui.replace(None);
            }
        ));

        self.imp().pair_ui.replace(Some(PairUi {
            dialog: dialog.clone(),
            prompt,
            code,
            spinner,
            error_icon,
            status,
            confirm_box,
        }));

        dialog.present(Some(self));

        // Kick off pairing.
        let client = self.client();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let s = client.pair().await;
                if s.ok() {
                    client.start_pair_poll();
                } else if let Some(ui) = page.imp().pair_ui.borrow().as_ref() {
                    ui.spinner.set_visible(false);
                    let m = if s.tail.is_empty() {
                        format!("Could not start pairing ({})", s.kind)
                    } else {
                        s.tail.clone()
                    };
                    ui.status.set_label(&m);
                }
            }
        ));
    }

    fn answer_pairing(&self, accept: bool) {
        let client = self.client();
        if let Some(ui) = self.imp().pair_ui.borrow().as_ref() {
            ui.confirm_box.set_visible(false);
            ui.spinner.set_visible(true);
            ui.status
                .set_label(if accept { "Completing pairing…" } else { "Declining…" });
        }
        glib::spawn_future_local(glib::clone!(
            #[strong]
            client,
            async move {
                client.confirm_pairing(accept).await;
            }
        ));
    }

    fn handle_pair_status(&self, kind: &str, msg: &str) {
        let ui_opt = self.imp().pair_ui.borrow().clone();
        let Some(ui) = ui_opt else {
            return; // no dialog open
        };

        if kind == "confirm" {
            ui.prompt
                .set_label("Verify this code matches the one shown on the watch, then Accept.");
            ui.code.set_label(msg);
            ui.code.set_visible(true);
            ui.spinner.set_visible(false);
            ui.error_icon.set_visible(false);
            ui.confirm_box.set_visible(true);
            ui.status
                .set_label("Does this code match the one shown on the watch?");
            return;
        }

        if kind == "ok" {
            self.toast("Watch paired");
            let client = self.client();
            glib::spawn_future_local(async move { client.refresh_watches().await });
            ui.dialog.close();
            return;
        }

        // pending / error / timeout / other.
        ui.confirm_box.set_visible(false);
        ui.code.set_visible(false);
        let is_error = kind == "error" || kind == "timeout";
        ui.error_icon.set_visible(is_error);
        ui.spinner.set_visible(kind.is_empty() || kind == "pending");
        ui.status
            .set_label(if msg.is_empty() { kind } else { msg });
    }

    // --- forget confirmation --------------------------------------------------

    fn open_forget_dialog(&self, name: &str) {
        let body = format!(
            "Forget “{name}”? This unpairs the watch from this host. You can pair it again later."
        );
        let dialog = adw::AlertDialog::new(Some("Forget watch"), Some(&body));
        dialog.add_response("cancel", "Cancel");
        dialog.add_response("forget", "Forget");
        dialog.set_response_appearance("forget", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");

        let name = name.to_string();
        dialog.connect_response(
            None,
            glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_, resp| {
                    if resp != "forget" {
                        return;
                    }
                    let client = page.client();
                    let name = name.clone();
                    glib::spawn_future_local(glib::clone!(
                        #[weak]
                        page,
                        #[strong]
                        client,
                        async move {
                            let s = client.unpair(&name).await;
                            if !s.ok() {
                                let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                                page.toast(&format!("Unpair failed: {m}"));
                            }
                            client.refresh_watches().await;
                        }
                    ));
                }
            ),
        );
        dialog.present(Some(self));
    }

    /// Headless smoke hook: render the details / debug / language pages so any
    /// runtime GTK issue in them surfaces (the harness only cycles top-level
    /// tabs and never taps the hero). No-op outside the smoke test.
    pub fn smoke_exercise(&self) {
        if std::env::var_os("STOANDL_SMOKE_MS").is_none() {
            return;
        }
        self.open_details();
        self.open_debug_page();
        self.open_language_page();
        self.open_battery();
        if let Some(bp) = self
            .imp()
            .nav_view
            .find_page("battery")
            .and_downcast::<super::battery::StoandlBatteryPage>()
        {
            bp.smoke_exercise(); // also hit the multi-day draw path
        }
        dbg_smoke("exercised details/debug/language/battery pages");
    }

    // --- battery insights (pushed navigation page) ----------------------------

    /// Push the rich battery-insights page (its own NavigationPage subclass). It
    /// fetches its own data on `bind_client`. Guarded against a double push.
    fn open_battery(&self) {
        if self.imp().nav_view.find_page("battery").is_some() {
            return;
        }
        let bp = super::battery::StoandlBatteryPage::new();
        bp.bind_client(&self.client());
        self.imp().nav_view.push(&bp);
    }

    // --- watch details (pushed navigation pages) ------------------------------

    /// Tap the hero → fetch the connected watch's details + dev state + language
    /// list, build the "details" page and push it. WatchDetails describes the
    /// CONNECTED watch only, so this is never wired from a disconnected row.
    fn open_details(&self) {
        let client = self.client();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let details = client.watch_details().await.unwrap_or_default();
                let dev_active = client.dev_connection_active().await;
                let langs = client.list_languages().await;
                // The hero row stays activatable during those awaits, so a second
                // tap can race a second push with the same "details" tag (an
                // Adw-CRITICAL). Only push if a details page isn't already up.
                if page.imp().nav_view.find_page("details").is_none() {
                    let dp = page.build_details_page(&details, dev_active, &langs);
                    page.imp().nav_view.push(&dp);
                }
            }
        ));
    }

    fn build_details_page(
        &self,
        d: &WatchDetails,
        dev_active: bool,
        langs: &[LanguageRow],
    ) -> adw::NavigationPage {
        let page_title = if d.code.is_empty() {
            if d.name.is_empty() { "Watch".to_string() } else { d.name.clone() }
        } else {
            format!("{} · {}", d.name, d.code)
        };

        let prefs = adw::PreferencesPage::new();

        // Facts.
        let facts = adw::PreferencesGroup::new();
        facts.add(&fact_row("Model", &d.model, false));
        facts.add(&fact_row("Platform", &d.platform, false));
        facts.add(&fact_row("Transport", &d.transport, false)); // already a human label
        facts.add(&self.firmware_fact_row(&d.firmware));
        facts.add(&fact_row("Serial", &d.serial, true));
        facts.add(&fact_row(
            "Battery",
            &if d.battery.is_empty() { String::new() } else { format!("{}%", d.battery) },
            false,
        ));
        facts.add(&fact_row("Last sync", &d.last_sync, false));
        prefs.add(&facts);

        // Developer connection + language.
        let conn_group = adw::PreferencesGroup::new();
        let dev_row = adw::SwitchRow::builder()
            .title("Developer connection")
            .subtitle("SDK / CloudPebble bridge on port 9000")
            .active(dev_active)
            .build();
        dev_row.connect_active_notify(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |row| page.toggle_dev_connection(row)
        ));
        conn_group.add(&dev_row);

        let current_lang = langs
            .iter()
            .find(|l| l.installed)
            .map(|l| l.display_name.clone())
            .unwrap_or_else(|| "—".to_string());
        let lang_row = adw::ActionRow::builder()
            .title("Language")
            .subtitle(&esc(&current_lang))
            .activatable(true)
            .build();
        lang_row.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
        lang_row.connect_activated(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.open_language_page()
        ));
        conn_group.add(&lang_row);
        // Keep a handle so a language-install success can refresh this subtitle
        // while the details page is still on the stack (under the language page).
        self.imp().details_lang_row.replace(Some(lang_row));
        prefs.add(&conn_group);

        // Main actions.
        let actions = adw::PreferencesGroup::new();
        let name = d.name.clone();
        actions.add(&action_row("Rename watch…", "document-edit-symbolic", false, glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            name,
            move || page.open_rename_dialog(&name)
        )));
        actions.add(&action_row("Capture screenshot", "camera-photo-symbolic", false, glib::clone!(
            #[weak(rename_to = page)]
            self,
            move || page.capture_screenshot()
        )));
        actions.add(&action_row("Check for updates", "view-refresh-symbolic", false, glib::clone!(
            #[weak(rename_to = page)]
            self,
            move || page.check_for_updates_toast()
        )));
        let debug_row = action_row("Debug…", "applications-utilities-symbolic", false, glib::clone!(
            #[weak(rename_to = page)]
            self,
            move || page.open_debug_page()
        ));
        debug_row.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
        actions.add(&debug_row);
        let name2 = d.name.clone();
        actions.add(&action_row("Forget watch", "user-trash-symbolic", true, glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            name2,
            move || {
                page.imp().nav_view.pop_to_tag("watch");
                page.open_forget_dialog(&name2);
            }
        )));
        prefs.add(&actions);

        wrap_page(&page_title, "details", &prefs)
    }

    fn firmware_fact_row(&self, firmware: &str) -> adw::ActionRow {
        let row = fact_row("Firmware", firmware, false);
        let btn = gtk::Button::builder().label("What’s new").valign(gtk::Align::Center).build();
        btn.add_css_class("flat");
        btn.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| {
                let client = page.client();
                glib::spawn_future_local(glib::clone!(
                    #[weak]
                    page,
                    #[strong]
                    client,
                    async move {
                        let (s, info) = client.check_firmware().await;
                        let url = info.map(|i| i.changelog_url).unwrap_or_default();
                        if s.ok() && !url.is_empty() {
                            let launcher = gtk::UriLauncher::new(&url);
                            let parent = page.root().and_downcast::<gtk::Window>();
                            launcher.launch(parent.as_ref(), gio::Cancellable::NONE, |_| {});
                        } else {
                            page.toast("No changelog available");
                        }
                    }
                ));
            }
        ));
        row.add_suffix(&btn);
        row
    }

    fn toggle_dev_connection(&self, row: &adw::SwitchRow) {
        let client = self.client();
        let want = row.is_active();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[weak]
            row,
            #[strong]
            client,
            async move {
                let s = if want {
                    client.start_dev_connection().await
                } else {
                    client.stop_dev_connection().await
                };
                if s.ok() {
                    if want {
                        let port = if s.tail.is_empty() { "9000".to_string() } else { s.tail.clone() };
                        page.toast(&format!("Developer connection · listening on {port}"));
                    } else {
                        page.toast("Developer connection stopped");
                    }
                } else {
                    // Revert the optimistic toggle without re-triggering the handler.
                    row.set_active(!want);
                    let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                    page.toast(&format!("Developer connection: {m}"));
                }
            }
        ));
    }

    fn capture_screenshot(&self) {
        let client = self.client();
        let path = temp_path("stoandl-screenshot", "png");
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let s = client.take_screenshot(&path).await;
                if s.ok() {
                    page.toast(&format!("Screenshot saved: {}", s.field(0)));
                } else {
                    let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                    page.toast(&format!("Screenshot: {m}"));
                }
            }
        ));
    }

    fn check_for_updates_toast(&self) {
        let client = self.client();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let (s, info) = client.check_firmware().await;
                if s.ok() {
                    match info {
                        Some(i) if i.update_available => {
                            page.toast(&format!("PebbleOS {} available", i.latest))
                        }
                        _ => page.toast("Firmware up to date"),
                    }
                } else {
                    let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                    page.toast(&format!("Firmware: {m}"));
                }
            }
        ));
    }

    // --- debug page -----------------------------------------------------------

    fn open_debug_page(&self) {
        let prefs = adw::PreferencesPage::new();

        let intro = adw::PreferencesGroup::builder()
            .description("Low-level tools for diagnostics and recovery. Use with care.")
            .build();
        intro.add(&action_row("Core dump", "documentinfo-symbolic", false, glib::clone!(
            #[weak(rename_to = page)]
            self,
            move || page.pull_core_dump()
        )));
        intro.add(&action_row("Pull watch logs", "text-x-generic-symbolic", false, glib::clone!(
            #[weak(rename_to = page)]
            self,
            move || page.pull_logs()
        )));
        intro.add(&action_row("Support bundle", "help-about-symbolic", false, glib::clone!(
            #[weak(rename_to = page)]
            self,
            move || page.build_support_bundle()
        )));
        intro.add(&action_row("Reboot to recovery (PRF)", "system-reboot-symbolic", false, glib::clone!(
            #[weak(rename_to = page)]
            self,
            move || page.confirm_reboot_recovery()
        )));
        intro.add(&action_row("Flash firmware from file…", "system-software-update-symbolic", false, glib::clone!(
            #[weak(rename_to = page)]
            self,
            move || page.pick_firmware_file()
        )));
        intro.add(&action_row("Write notification…", "mail-unread-symbolic", false, glib::clone!(
            #[weak(rename_to = page)]
            self,
            move || page.open_test_notification_dialog()
        )));
        intro.add(&action_row("Factory reset", "dialog-warning-symbolic", true, glib::clone!(
            #[weak(rename_to = page)]
            self,
            move || page.confirm_factory_reset()
        )));
        prefs.add(&intro);

        let dp = wrap_page("Debug", "debug", &prefs);
        self.imp().nav_view.push(&dp);
    }

    fn pull_core_dump(&self) {
        let client = self.client();
        let path = temp_path("stoandl-coredump", "bin");
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let s = client.get_core_dump(&path).await;
                let msg = match s.kind.as_str() {
                    "ok" => format!("Core dump saved: {}", s.field(0)),
                    "none" => "No core dump available".to_string(),
                    _ => format!("Core dump: {}", if s.tail.is_empty() { &s.kind } else { &s.tail }),
                };
                page.toast(&msg);
            }
        ));
    }

    fn pull_logs(&self) {
        let client = self.client();
        let path = temp_path("stoandl-logs", "txt");
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let s = client.gather_logs(&path).await;
                if s.ok() {
                    page.toast(&format!("Logs saved: {}", s.field(0)));
                } else {
                    let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                    page.toast(&format!("Logs: {m}"));
                }
            }
        ));
    }

    fn build_support_bundle(&self) {
        // CLI shell-out (co-located `stoandl` binary), not on D-Bus.
        self.toast("Building support bundle…");
        let argv: &[&std::ffi::OsStr] = &[
            std::ffi::OsStr::new("stoandl"),
            std::ffi::OsStr::new("support"),
        ];
        match gio::Subprocess::newv(
            argv,
            gio::SubprocessFlags::STDOUT_PIPE | gio::SubprocessFlags::STDERR_MERGE,
        ) {
            Ok(proc) => {
                glib::spawn_future_local(glib::clone!(
                    #[weak(rename_to = page)]
                    self,
                    async move {
                        match proc.communicate_utf8_future(None).await {
                            Ok((out, _)) => {
                                let ok = proc.is_successful();
                                let text = out.map(|s| s.trim().to_string()).unwrap_or_default();
                                if ok {
                                    page.toast("Support bundle created");
                                } else {
                                    page.toast(&format!("Support bundle failed: {text}"));
                                }
                            }
                            Err(e) => page.toast(&format!("Support bundle failed: {e}")),
                        }
                    }
                ));
            }
            Err(_) => self.toast("Support bundle failed: stoandl CLI not found on PATH"),
        }
    }

    fn confirm_reboot_recovery(&self) {
        let dialog = adw::AlertDialog::new(
            Some("Reboot to recovery"),
            Some("Reboot the watch into recovery (PRF) firmware?"),
        );
        dialog.add_response("cancel", "Cancel");
        dialog.add_response("reboot", "Reboot");
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        dialog.connect_response(
            None,
            glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_, resp| {
                    if resp != "reboot" {
                        return;
                    }
                    let client = page.client();
                    glib::spawn_future_local(glib::clone!(
                        #[weak]
                        page,
                        #[strong]
                        client,
                        async move {
                            let s = client.reset_into_recovery().await;
                            let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                            let msg = if s.ok() { "Recovery reboot queued".to_string() } else { format!("Failed: {m}") };
                            page.toast(&msg);
                        }
                    ));
                }
            ),
        );
        dialog.present(Some(self));
    }

    fn confirm_factory_reset(&self) {
        let dialog = adw::AlertDialog::new(
            Some("Factory reset"),
            Some("This wipes the watch to its out-of-box state and reboots it. This cannot be undone."),
        );
        let entry = adw::EntryRow::builder().title("Type yes to confirm").build();
        let group = adw::PreferencesGroup::new();
        group.add(&entry);
        dialog.set_extra_child(Some(&group));
        dialog.add_response("cancel", "Cancel");
        dialog.add_response("reset", "Factory reset");
        dialog.set_response_appearance("reset", adw::ResponseAppearance::Destructive);
        dialog.set_response_enabled("reset", false);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");

        entry.connect_changed(glib::clone!(
            #[weak]
            dialog,
            move |e| {
                let ok = e.text().trim().eq_ignore_ascii_case("yes");
                dialog.set_response_enabled("reset", ok);
            }
        ));
        dialog.connect_response(
            None,
            glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_, resp| {
                    if resp != "reset" {
                        return;
                    }
                    let client = page.client();
                    glib::spawn_future_local(glib::clone!(
                        #[weak]
                        page,
                        #[strong]
                        client,
                        async move {
                            let s = client.factory_reset().await;
                            let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                            let msg = if s.ok() { "Factory reset queued".to_string() } else { format!("Failed: {m}") };
                            page.toast(&msg);
                        }
                    ));
                }
            ),
        );
        dialog.present(Some(self));
    }

    /// Compose + send a test notification (Title + optional Body) through the
    /// daemon's normal mute/style/filter path. Send is enabled only with a title.
    fn open_test_notification_dialog(&self) {
        let dialog = adw::AlertDialog::new(
            Some("Write notification"),
            Some("Send a test notification to the watch through the normal mute, style and filter path."),
        );
        let group = adw::PreferencesGroup::new();
        let title_row = adw::EntryRow::builder().title("Title").build();
        let body_row = adw::EntryRow::builder().title("Body (optional)").build();
        group.add(&title_row);
        group.add(&body_row);
        dialog.set_extra_child(Some(&group));
        dialog.add_response("cancel", "Cancel");
        dialog.add_response("send", "Send");
        dialog.set_response_appearance("send", adw::ResponseAppearance::Suggested);
        dialog.set_response_enabled("send", false);
        dialog.set_default_response(Some("send"));
        dialog.set_close_response("cancel");

        title_row.connect_changed(glib::clone!(
            #[weak]
            dialog,
            move |e| dialog.set_response_enabled("send", !e.text().trim().is_empty())
        ));
        dialog.connect_response(
            None,
            glib::clone!(
                #[weak(rename_to = page)]
                self,
                #[weak]
                title_row,
                #[weak]
                body_row,
                move |_, resp| {
                    if resp != "send" {
                        return;
                    }
                    let title = title_row.text().to_string();
                    let body = body_row.text().to_string();
                    let client = page.client();
                    glib::spawn_future_local(glib::clone!(
                        #[weak]
                        page,
                        #[strong]
                        client,
                        async move {
                            let s = client.send_test_notification(&title, &body).await;
                            let msg = if s.ok() {
                                "Test notification sent".to_string()
                            } else {
                                let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                                format!("Notification: {m}")
                            };
                            page.toast(&msg);
                        }
                    ));
                }
            ),
        );
        dialog.present(Some(self));
        title_row.grab_focus(); // a compose dialog focuses its first entry (HIG)
    }

    fn pick_firmware_file(&self) {
        let filter = gtk::FileFilter::new();
        filter.set_name(Some("Pebble firmware (*.pbz)"));
        filter.add_suffix("pbz");
        let filters = gio::ListStore::new::<gtk::FileFilter>();
        filters.append(&filter);

        let dialog = gtk::FileDialog::builder()
            .title("Flash firmware (.pbz)")
            .filters(&filters)
            .build();
        let parent = self.root().and_downcast::<gtk::Window>();
        dialog.open(
            parent.as_ref(),
            gio::Cancellable::NONE,
            glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |res| {
                    if let Ok(file) = res {
                        if let Some(path) = file.path() {
                            page.confirm_flash_file(&path.to_string_lossy());
                        }
                    }
                }
            ),
        );
    }

    fn confirm_flash_file(&self, path: &str) {
        let basename = std::path::Path::new(path)
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.to_string());
        let body = format!(
            "Flash “{basename}” onto the watch? Keep it on charge and in range; don’t power it off during the flash."
        );
        let dialog = adw::AlertDialog::new(Some("Flash firmware"), Some(&body));
        dialog.add_response("cancel", "Cancel");
        dialog.add_response("flash", "Flash");
        dialog.set_response_appearance("flash", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");

        let path = path.to_string();
        dialog.connect_response(
            None,
            glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_, resp| {
                    if resp != "flash" {
                        return;
                    }
                    let client = page.client();
                    let path = path.clone();
                    glib::spawn_future_local(glib::clone!(
                        #[weak]
                        page,
                        #[strong]
                        client,
                        async move {
                            let s = client.sideload_firmware(&path).await;
                            if s.ok() {
                                page.toast("Flashing firmware…");
                                // Pop to the Watch root so its flash-progress card shows.
                                page.imp().nav_view.pop_to_tag("watch");
                            } else {
                                let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                                page.toast(&format!("Flash failed: {m}"));
                            }
                        }
                    ));
                }
            ),
        );
        dialog.present(Some(self));
    }

    // --- rename ---------------------------------------------------------------

    fn open_rename_dialog(&self, current: &str) {
        let dialog = adw::AlertDialog::new(Some("Rename watch"), Some("Choose a display name for this watch."));
        let entry = adw::EntryRow::builder().title("Watch name").build();
        entry.set_text(current);
        let group = adw::PreferencesGroup::new();
        group.add(&entry);
        dialog.set_extra_child(Some(&group));
        dialog.add_response("cancel", "Cancel");
        dialog.add_response("rename", "Rename");
        dialog.set_response_appearance("rename", adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some("rename"));
        dialog.set_close_response("cancel");
        dialog.set_response_enabled("rename", !current.trim().is_empty());

        entry.connect_changed(glib::clone!(
            #[weak]
            dialog,
            move |e| dialog.set_response_enabled("rename", !e.text().trim().is_empty())
        ));

        let current = current.to_string();
        dialog.connect_response(
            None,
            glib::clone!(
                #[weak(rename_to = page)]
                self,
                #[weak]
                entry,
                move |_, resp| {
                    if resp != "rename" {
                        return;
                    }
                    let new_name = entry.text().trim().to_string();
                    if new_name.is_empty() {
                        return;
                    }
                    let client = page.client();
                    let current = current.clone();
                    glib::spawn_future_local(glib::clone!(
                        #[weak]
                        page,
                        #[strong]
                        client,
                        async move {
                            let s = client.set_watch_nickname(&current, &new_name).await;
                            if s.ok() {
                                page.toast(&format!("Renamed to {new_name}"));
                                client.refresh_watches().await;
                                page.imp().nav_view.pop_to_tag("watch");
                            } else {
                                let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                                page.toast(&format!("Rename failed: {m}"));
                            }
                        }
                    ));
                }
            ),
        );
        dialog.present(Some(self));
    }

    // --- language page --------------------------------------------------------

    fn open_language_page(&self) {
        let prefs = adw::PreferencesPage::new();

        // Install-progress group (hidden until an install is in flight). The group
        // title is a stable section header; the live phase/percent rides on the bar's
        // own text (never the group title).
        let progress_group = adw::PreferencesGroup::builder()
            .title("Installing language pack")
            .build();
        let progressbar = gtk::ProgressBar::builder()
            .margin_top(6)
            .margin_bottom(6)
            .show_text(true)
            .build();
        progress_group.add(&progressbar);
        progress_group.set_visible(false);
        prefs.add(&progress_group);
        self.imp().lang_progress_group.replace(Some(progress_group));
        self.imp().lang_progressbar.replace(Some(progressbar));
        // Reflect any install that's already in flight when the page is (re)opened.
        self.update_lang_progress("");

        let group = adw::PreferencesGroup::builder()
            .description("Load a language pack onto the watch. The current one is marked.")
            .build();
        prefs.add(&group);
        self.imp().lang_group.replace(Some(group.clone()));
        self.imp().lang_rows.borrow_mut().clear();

        // Populate from a fresh fetch.
        let client = self.client();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let langs = client.list_languages().await;
                page.rebuild_languages(&langs);
            }
        ));

        let dp = wrap_page("Watch language", "language", &prefs);
        // Forget our language-group handle once this page is popped.
        dp.connect_hidden(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| {
                page.imp().lang_group.replace(None);
                page.imp().lang_rows.borrow_mut().clear();
                page.imp().lang_progress_group.replace(None);
                page.imp().lang_progressbar.replace(None);
            }
        ));
        self.imp().nav_view.push(&dp);
    }

    fn rebuild_languages(&self, langs: &[LanguageRow]) {
        let imp = self.imp();
        let Some(group) = imp.lang_group.borrow().clone() else {
            return;
        };
        for w in imp.lang_rows.borrow_mut().drain(..) {
            group.remove(&w);
        }
        for l in langs {
            let row = adw::ActionRow::builder()
                .title(&esc(&l.display_name))
                .subtitle(&esc(&format!("{} · {}", l.id, l.source)))
                .activatable(true)
                .build();
            let icon = gtk::Image::from_icon_name("preferences-desktop-locale-symbolic");
            if l.installed {
                icon.add_css_class("accent");
            }
            row.add_prefix(&icon);
            if l.installed {
                let check = gtk::Image::from_icon_name("object-select-symbolic");
                check.add_css_class("accent");
                row.add_suffix(&check);
            }
            let id = l.id.clone();
            let display = l.display_name.clone();
            let installed = l.installed;
            row.connect_activated(glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_| {
                    if installed {
                        page.toast(&format!("{display} already loaded"));
                        return;
                    }
                    let client = page.client();
                    let id = id.clone();
                    let display = display.clone();
                    glib::spawn_future_local(glib::clone!(
                        #[weak]
                        page,
                        #[strong]
                        client,
                        async move {
                            let s = client.install_language(&id).await;
                            if s.ok() {
                                page.toast(&format!("Loading {display} onto watch…"));
                                // Show the indeterminate bar immediately, before the
                                // first LanguageProgress signal arrives.
                                page.imp().lang_busy.set(true);
                                page.imp().lang_percent.set(-1);
                                page.update_lang_progress("downloading");
                            } else {
                                let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                                page.toast(&format!("Language: {m}"));
                            }
                        }
                    ));
                }
            ));
            group.add(&row);
            imp.lang_rows.borrow_mut().push(row.upcast());
        }
    }

    /// Show/hide + drive the language install progress bar from the current
    /// `lang_busy`/`lang_percent` state (indeterminate pulse until a % arrives).
    fn update_lang_progress(&self, phase: &str) {
        let imp = self.imp();
        let busy = imp.lang_busy.get();
        if let Some(g) = imp.lang_progress_group.borrow().as_ref() {
            g.set_visible(busy);
        }
        if busy {
            if let Some(bar) = imp.lang_progressbar.borrow().as_ref() {
                let pct = imp.lang_percent.get();
                bar.set_text(Some(&lang_phase_label(phase, pct))); // live status on the bar itself
                if pct < 0 {
                    bar.pulse();
                } else {
                    bar.set_fraction(pct as f64 / 100.0);
                }
            }
        }
    }

    fn handle_language_status(&self, kind: &str, percent: i32, detail: &str) {
        let imp = self.imp();
        match kind {
            "success" | "failed" | "disconnected" => {
                imp.lang_busy.set(false);
                self.update_lang_progress("");
            }
            "idle" | "notready" | "" => {}
            _ => {
                // downloading / installing / inprogress — live install in flight.
                imp.lang_busy.set(true);
                imp.lang_percent.set(percent);
                self.update_lang_progress(kind);
            }
        }
        match kind {
            "success" => {
                self.toast("Language pack installed");
                // Re-fetch once; refresh both the language page (if open) and the
                // details page's Language subtitle (if it's still on the stack).
                let client = self.client();
                glib::spawn_future_local(glib::clone!(
                    #[weak(rename_to = page)]
                    self,
                    #[strong]
                    client,
                    async move {
                        let langs = client.list_languages().await;
                        page.rebuild_languages(&langs); // no-op if the language page is closed
                        let row_opt = page.imp().details_lang_row.borrow().clone();
                        if let Some(row) = row_opt {
                            let current = langs
                                .iter()
                                .find(|l| l.installed)
                                .map(|l| l.display_name.clone())
                                .unwrap_or_else(|| "—".to_string());
                            row.set_subtitle(&esc(&current));
                        }
                    }
                ));
            }
            "failed" => self.toast(&format!("Language install failed: {detail}")),
            "disconnected" => self.toast("Watch disconnected during install"),
            _ => {}
        }
    }
}

// --- shared row/page builders ------------------------------------------------

/// A label/value fact row (value right-aligned; "—" when empty; mono optional).
fn fact_row(label: &str, value: &str, mono: bool) -> adw::ActionRow {
    let row = adw::ActionRow::builder().title(label).build();
    let v = if value.is_empty() { "—" } else { value };
    let vl = gtk::Label::new(Some(v));
    vl.set_selectable(mono); // serials are handy to copy
    if mono {
        vl.add_css_class("mono");
    } else {
        vl.add_css_class("dim-label");
    }
    row.add_suffix(&vl);
    row
}

/// An activatable action row (leading icon, optional destructive styling).
fn action_row<F: Fn() + 'static>(
    label: &str,
    icon: &str,
    danger: bool,
    on_activate: F,
) -> adw::ActionRow {
    let row = adw::ActionRow::builder().title(label).activatable(true).build();
    let img = gtk::Image::from_icon_name(icon);
    row.add_prefix(&img);
    if danger {
        row.add_css_class("error");
    }
    row.connect_activated(move |_| on_activate());
    row
}

/// Wrap a PreferencesPage in a titled NavigationPage. A pushed page is the sole
/// surface, so its header keeps the window controls (and gets a back button).
fn wrap_page(title: &str, tag: &str, prefs: &adw::PreferencesPage) -> adw::NavigationPage {
    let header = adw::HeaderBar::new();
    let tv = adw::ToolbarView::new();
    tv.add_top_bar(&header);
    tv.set_content(Some(prefs));
    adw::NavigationPage::builder()
        .title(title)
        .tag(tag)
        .child(&tv)
        .build()
}
