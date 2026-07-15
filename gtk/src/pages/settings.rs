//! The Settings tab (`StoandlSettingsPage`) — a landing list of categories that
//! push focused sub-pages (port of `qml/SettingsPage.qml` + the 5 sub-pages).
//! Sub-pages are built in Rust and pushed onto the tab's `Adw.NavigationView`.

use std::cell::{OnceCell, RefCell};
use std::ffi::OsStr;

use adw::prelude::*;
use adw::subclass::prelude::*;
use gtk::{gio, glib, CompositeTemplate};

use super::esc;
use crate::dbus::{Calendar, CalendarSource, StoandlClient, WatchPref};
use crate::window::StoandlWindow;

fn source_icon(t: &str) -> &'static str {
    match t {
        "caldav" => "folder-remote-symbolic",
        "ical" => "appointment-new-symbolic",
        "ics" => "folder-symbolic",
        _ => "edit-find-symbolic",
    }
}
fn source_type_label(t: &str) -> &'static str {
    match t {
        "caldav" => "CalDAV account",
        "ical" => "iCal feed",
        "ics" => "local calendar",
        _ => "discovered calendars",
    }
}

/// The 9 watch-pref sections (id-prefix grouped; first match wins, "Other" last).
const WP_SECTIONS: [&str; 9] = [
    "Quick launch",
    "Display and backlight",
    "Notifications",
    "Quiet Time",
    "Vibration",
    "Music",
    "Motion and menus",
    "Clock and language",
    "Other",
];

fn wp_section(id: &str) -> usize {
    if id.starts_with("ql") {
        0
    } else if id.starts_with("light")
        || id == "textStyle"
        || id == "displayOrientationLeftHanded"
        || id == "dynBacklightMinThreshold"
    {
        1
    } else if id.starts_with("notif") || id == "mask" || id.starts_with("timelineQuickView") {
        2
    } else if id.starts_with("dnd") {
        3
    } else if id.contains("vibe") {
        4
    } else if id.starts_with("music") {
        5
    } else if id == "motionSensitivity" || id == "stationaryMode" || id.starts_with("menuScroll") {
        6
    } else if id == "clock24h" || id == "timezoneSource" || id == "langEnglish" {
        7
    } else {
        8
    }
}

/// Parse a watch color (`0xRRGGBB` / `#RRGGBB`) to normalised RGB for the swatch.
fn parse_hex(s: &str) -> (f64, f64, f64) {
    let h = s.trim().trim_start_matches("0x").trim_start_matches("0X").trim_start_matches('#');
    let h = if h.len() >= 6 { &h[h.len() - 6..] } else { "000000" };
    let n = u32::from_str_radix(h, 16).unwrap_or(0);
    (
        ((n >> 16) & 0xff) as f64 / 255.0,
        ((n >> 8) & 0xff) as f64 / 255.0,
        (n & 0xff) as f64 / 255.0,
    )
}

fn dbg_smoke(msg: &str) {
    if std::env::var_os("STOANDL_SMOKE_MS").is_some() {
        eprintln!("stoandl-smoke: {msg}");
    }
}

fn sync_label(service: &str) -> &'static str {
    match service {
        "weather" => "Weather",
        "calendar" => "Calendar",
        "music" => "Music",
        "health" => "Health",
        "dnd" => "Do Not Disturb",
        _ => "Sync",
    }
}
fn sync_icon(service: &str) -> &'static str {
    match service {
        "weather" => "weather-clear-symbolic",
        "calendar" => "x-office-calendar-symbolic",
        "music" => "media-playback-start-symbolic",
        "health" => "emblem-favorite-symbolic",
        "dnd" => "notifications-disabled-symbolic",
        _ => "emblem-synchronizing-symbolic",
    }
}

mod imp {
    use super::*;

    #[derive(CompositeTemplate, Default)]
    #[template(resource = "/de/yoxcu/stoandl/gui/ui/settings.ui")]
    pub struct StoandlSettingsPage {
        #[template_child]
        pub nav_view: TemplateChild<adw::NavigationView>,
        #[template_child]
        pub sync_row: TemplateChild<adw::ActionRow>,
        #[template_child]
        pub calendars_row: TemplateChild<adw::ActionRow>,
        #[template_child]
        pub watch_row: TemplateChild<adw::ActionRow>,
        #[template_child]
        pub general_row: TemplateChild<adw::ActionRow>,
        #[template_child]
        pub backup_row: TemplateChild<adw::ActionRow>,
        #[template_child]
        pub view_switcher: TemplateChild<adw::ViewSwitcher>,
        #[template_child]
        pub switcher_bar: TemplateChild<adw::ViewSwitcherBar>,

        pub client: OnceCell<StoandlClient>,
        // Sync sub-page (persisted so force-sync/toggle can refresh Last-sync).
        pub sync_group: RefCell<Option<adw::PreferencesGroup>>,
        pub sync_rows: RefCell<Vec<gtk::Widget>>,
        // General sub-page (persisted so SetConfig can re-fetch).
        pub general_group: RefCell<Option<adw::PreferencesGroup>>,
        pub general_rows: RefCell<Vec<gtk::Widget>>,
        // Watch-prefs sub-page rebuild state (re-fetch after each mutation).
        pub wp_page: RefCell<Option<adw::PreferencesPage>>,
        pub wp_groups: RefCell<Vec<adw::PreferencesGroup>>,
        pub app_titles: RefCell<Vec<String>>,
        pub wp_debounce: RefCell<Option<glib::SourceId>>, // single pending number-write timer
        // Calendars sub-page rebuild state.
        pub cal_page: RefCell<Option<adw::PreferencesPage>>,
        pub cal_groups: RefCell<Vec<adw::PreferencesGroup>>,
        pub cal_sources: RefCell<Vec<CalendarSource>>,
        pub cal_discover: RefCell<Option<adw::SwitchRow>>, // per-push, mirrors cal_page
        pub cal_discover_on: std::cell::Cell<bool>,
        pub cal_bound: std::cell::Cell<bool>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for StoandlSettingsPage {
        const NAME: &'static str = "StoandlSettingsPage";
        type Type = super::StoandlSettingsPage;
        type ParentType = adw::BreakpointBin;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }
        fn instance_init(obj: &glib::subclass::InitializingObject<Self>) {
            obj.init_template();
        }
    }

    impl ObjectImpl for StoandlSettingsPage {}
    impl WidgetImpl for StoandlSettingsPage {}
    impl BreakpointBinImpl for StoandlSettingsPage {}
}

glib::wrapper! {
    pub struct StoandlSettingsPage(ObjectSubclass<imp::StoandlSettingsPage>)
        @extends adw::BreakpointBin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl Default for StoandlSettingsPage {
    fn default() -> Self {
        Self::new()
    }
}

impl StoandlSettingsPage {
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

    fn toast(&self, msg: &str) {
        if let Some(win) = self.root().and_downcast::<StoandlWindow>() {
            win.toast(msg);
        }
    }

    fn nav(&self) -> adw::NavigationView {
        self.imp().nav_view.get()
    }

    pub fn bind_client(&self, client: &StoandlClient) {
        self.imp().client.set(client.clone()).ok();
        self.imp().sync_row.connect_activated(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.push_sync()
        ));
        self.imp().calendars_row.connect_activated(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.push_calendars()
        ));
        self.imp().watch_row.connect_activated(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.push_watch_prefs()
        ));
        self.imp().general_row.connect_activated(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.push_general()
        ));
        self.imp().backup_row.connect_activated(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.push_backup()
        ));

        // Drop cached sub-page handles when their page is popped, so a background
        // signal / settle timer can't rebuild an off-screen, detached page.
        self.imp().nav_view.connect_popped(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_, popped| {
                let imp = page.imp();
                match popped.tag().as_deref() {
                    Some("watchprefs") => {
                        imp.wp_page.replace(None);
                        imp.wp_groups.borrow_mut().clear();
                    }
                    Some("calendars") => {
                        imp.cal_page.replace(None);
                        imp.cal_groups.borrow_mut().clear();
                        imp.cal_discover.replace(None);
                    }
                    Some("sync") => {
                        imp.sync_group.replace(None);
                        imp.sync_rows.borrow_mut().clear();
                    }
                    Some("general") => {
                        imp.general_group.replace(None);
                        imp.general_rows.borrow_mut().clear();
                    }
                    _ => {}
                }
            }
        ));
    }

    /// A sub-page shell: ToolbarView + header carrying the title + optional end
    /// action. A pushed page is the sole surface, so it keeps the window controls
    /// (and gets a back button).
    fn nav_page(
        title: &str,
        tag: &str,
        content: &impl IsA<gtk::Widget>,
        header_end: Option<&gtk::Widget>,
    ) -> adw::NavigationPage {
        let header = adw::HeaderBar::new();
        if let Some(w) = header_end {
            header.pack_end(w);
        }
        let tv = adw::ToolbarView::new();
        tv.add_top_bar(&header);
        tv.set_content(Some(content));
        adw::NavigationPage::builder().title(title).tag(tag).child(&tv).build()
    }

    // --- Sync sub-page --------------------------------------------------------

    fn push_sync(&self) {
        let prefs = adw::PreferencesPage::new();
        let services = adw::PreferencesGroup::builder().title("Services").build();
        prefs.add(&services);

        let syncnow = adw::PreferencesGroup::builder().title("Sync now").build();
        for (svc, label) in [("weather", "Weather"), ("calendar", "Calendar"), ("health", "Health")] {
            let row = adw::ActionRow::builder().title(label).activatable(true).build();
            row.add_prefix(&gtk::Image::from_icon_name(sync_icon(svc)));
            let svc = svc.to_string();
            row.connect_activated(glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_| page.force_sync(&svc)
            ));
            syncnow.add(&row);
        }
        prefs.add(&syncnow);

        let manage = adw::PreferencesGroup::new();
        let manage_row = adw::ActionRow::builder()
            .title("Manage calendars…")
            .subtitle("CalDAV accounts, iCal feeds and which calendars sync")
            .activatable(true)
            .build();
        manage_row.add_prefix(&gtk::Image::from_icon_name("x-office-calendar-symbolic"));
        manage_row.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
        manage_row.connect_activated(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.push_calendars()
        ));
        manage.add(&manage_row);
        prefs.add(&manage);

        let sync_all = gtk::Button::from_icon_name("view-refresh-symbolic");
        sync_all.set_tooltip_text(Some("Sync all now"));
        sync_all.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| {
                for svc in ["weather", "calendar", "health"] {
                    page.force_sync(svc);
                }
            }
        ));

        self.imp().sync_group.replace(Some(services));
        let np = Self::nav_page("Sync", "sync", &prefs, Some(sync_all.upcast_ref()));
        self.nav().push(&np);
        self.reload_sync_services();
    }

    fn reload_sync_services(&self) {
        let Some(group) = self.imp().sync_group.borrow().clone() else {
            return; // the Sync sub-page isn't open
        };
        let client = self.client();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                for w in page.imp().sync_rows.borrow_mut().drain(..) {
                    group.remove(&w);
                }
                for s in client.get_sync_status().await {
                    if s.service == "notifications" {
                        continue; // lives on the Notifications tab
                    }
                    let row = adw::SwitchRow::builder()
                        .title(sync_label(&s.service))
                        .subtitle(&format!(
                            "Last sync · {}",
                            if s.last_sync.is_empty() { "never".into() } else { esc(&s.last_sync) }
                        ))
                        .active(s.enabled)
                        .sensitive(s.available)
                        .build();
                    row.add_prefix(&gtk::Image::from_icon_name(sync_icon(&s.service)));
                    let svc = s.service.clone();
                    row.connect_active_notify(glib::clone!(
                        #[weak]
                        page,
                        move |r| page.toggle_sync(&svc, r.is_active())
                    ));
                    group.add(&row);
                    page.imp().sync_rows.borrow_mut().push(row.upcast());
                }
                dbg_smoke("settings: sync services loaded");
            }
        ));
    }

    fn toggle_sync(&self, service: &str, on: bool) {
        let client = self.client();
        let service = service.to_string();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let s = client.set_sync_enabled(&service, on).await;
                if !s.ok() {
                    let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                    page.toast(&format!("{}: {m}", sync_label(&service)));
                }
                page.reload_sync_services(); // re-fetch (available/lastSync may change)
            }
        ));
    }

    fn force_sync(&self, service: &str) {
        let client = self.client();
        let service = service.to_string();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let s = match service.as_str() {
                    "weather" => client.sync_weather().await,
                    "calendar" => client.sync_calendar().await,
                    _ => client.sync_health().await,
                };
                let label = sync_label(&service);
                if s.ok() {
                    page.toast(&format!("{label} synced"));
                } else {
                    let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                    page.toast(&format!("{label}: {m}"));
                }
                page.reload_sync_services(); // a force-sync updates the Last-sync label
            }
        ));
    }

    // --- General (daemon config) sub-page ------------------------------------

    fn push_general(&self) {
        let prefs = adw::PreferencesPage::new();
        let group = adw::PreferencesGroup::new();
        prefs.add(&group);
        self.imp().general_group.replace(Some(group));
        let np = Self::nav_page("Daemon configuration", "general", &prefs, None);
        self.nav().push(&np);
        self.reload_general();
    }

    fn reload_general(&self) {
        let Some(group) = self.imp().general_group.borrow().clone() else {
            return;
        };
        let client = self.client();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                for w in page.imp().general_rows.borrow_mut().drain(..) {
                    group.remove(&w);
                }
                let schema = client.config_schema().await;
                let values: std::collections::HashMap<String, String> =
                    client.get_config().await.into_iter().collect();
                for f in &schema {
                    let cur = values.get(&f.key).cloned().unwrap_or_default();
                    let key = f.key.clone();
                    match f.field_type.as_str() {
                        "toggle" => {
                            let row = adw::SwitchRow::builder()
                                .title(&esc(&f.label))
                                .subtitle(&esc(&f.desc))
                                .active(cur == "true")
                                .build();
                            row.connect_active_notify(glib::clone!(
                                #[weak]
                                page,
                                move |r| page.apply_config(&key, if r.is_active() { "true" } else { "false" })
                            ));
                            group.add(&row);
                            page.imp().general_rows.borrow_mut().push(row.upcast());
                        }
                        "combo" => {
                            let model = gtk::StringList::new(
                                &f.options.iter().map(String::as_str).collect::<Vec<_>>(),
                            );
                            let row = adw::ComboRow::builder()
                                .title(&esc(&f.label))
                                .subtitle(&esc(&f.desc))
                                .model(&model)
                                .build();
                            row.set_selected(
                                f.options.iter().position(|o| *o == cur).unwrap_or(0) as u32,
                            );
                            let opts = f.options.clone();
                            row.connect_selected_notify(glib::clone!(
                                #[weak]
                                page,
                                move |r| {
                                    if let Some(v) = opts.get(r.selected() as usize) {
                                        page.apply_config(&key, v);
                                    }
                                }
                            ));
                            group.add(&row);
                            page.imp().general_rows.borrow_mut().push(row.upcast());
                        }
                        _ => {
                            let row = adw::EntryRow::builder().title(&esc(&f.label)).build();
                            row.set_text(&cur);
                            let prev = cur.clone();
                            row.connect_apply(glib::clone!(
                                #[weak]
                                page,
                                move |r| {
                                    let v = r.text().to_string();
                                    if v != prev {
                                        page.apply_config(&key, &v);
                                    }
                                }
                            ));
                            group.add(&row);
                            page.imp().general_rows.borrow_mut().push(row.upcast());
                        }
                    }
                }
                dbg_smoke(&format!("settings: general loaded {} keys", schema.len()));
            }
        ));
    }

    fn apply_config(&self, key: &str, value: &str) {
        let client = self.client();
        let (key, value) = (key.to_string(), value.to_string());
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let s = client.set_config(&key, &value).await;
                if !s.ok() {
                    let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                    page.toast(&format!("Config: {m}"));
                }
                page.reload_general(); // re-fetch is authoritative (Qt reloads the page)
            }
        ));
    }

    // --- Backup & diagnostics sub-page ---------------------------------------

    fn push_backup(&self) {
        let prefs = adw::PreferencesPage::new();

        let backup = adw::PreferencesGroup::builder().title("Backup").build();
        let back_row = adw::ActionRow::builder()
            .title("Back up now")
            .subtitle("Save a full backup of the watch and daemon state")
            .activatable(true)
            .build();
        back_row.add_prefix(&gtk::Image::from_icon_name("document-save-symbolic"));
        back_row.connect_activated(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.run_cli(&["backup"], "Backing up…", "Backup complete", "Backup failed")
        ));
        backup.add(&back_row);
        let restore_row = adw::ActionRow::builder()
            .title("Restore from file…")
            .subtitle("Restore a previously saved backup")
            .activatable(true)
            .build();
        restore_row.add_prefix(&gtk::Image::from_icon_name("document-open-symbolic"));
        restore_row.connect_activated(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.pick_restore()
        ));
        backup.add(&restore_row);
        prefs.add(&backup);

        let diag = adw::PreferencesGroup::builder().title("Diagnostics").build();
        let support_row = adw::ActionRow::builder()
            .title("Create support bundle")
            .subtitle("Collect logs and diagnostics for a bug report")
            .activatable(true)
            .build();
        support_row.add_prefix(&gtk::Image::from_icon_name("help-about-symbolic"));
        support_row.connect_activated(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| {
                page.run_cli(&["support"], "Building support bundle…", "Support bundle created", "Support bundle failed")
            }
        ));
        diag.add(&support_row);
        prefs.add(&diag);

        let np = Self::nav_page("Backup & diagnostics", "backup", &prefs, None);
        self.nav().push(&np);
    }

    fn pick_restore(&self) {
        let filter = gtk::FileFilter::new();
        filter.set_name(Some("Backup archives"));
        for s in ["tar", "tar.gz", "tgz", "zip"] {
            filter.add_suffix(s);
        }
        let filters = gio::ListStore::new::<gtk::FileFilter>();
        filters.append(&filter);
        let dialog = gtk::FileDialog::builder().title("Restore from backup").filters(&filters).build();
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
                            page.run_cli(
                                &["restore", &path.to_string_lossy()],
                                "Restoring…",
                                "Restore complete",
                                "Restore failed",
                            );
                        }
                    }
                }
            ),
        );
    }

    /// Shell out to the co-located `stoandl` CLI (backup/restore/support are not
    /// on D-Bus); toast the pending message now and the result on completion.
    fn run_cli(&self, args: &[&str], pending: &str, ok_msg: &str, fail_prefix: &str) {
        self.toast(pending);
        let mut argv: Vec<&OsStr> = Vec::with_capacity(args.len() + 1);
        argv.push(OsStr::new("stoandl"));
        for a in args {
            argv.push(OsStr::new(*a));
        }
        let (ok_msg, fail_prefix) = (ok_msg.to_string(), fail_prefix.to_string());
        match gio::Subprocess::newv(
            &argv,
            gio::SubprocessFlags::STDOUT_PIPE | gio::SubprocessFlags::STDERR_MERGE,
        ) {
            Ok(proc) => {
                glib::spawn_future_local(glib::clone!(
                    #[weak(rename_to = page)]
                    self,
                    async move {
                        match proc.communicate_utf8_future(None).await {
                            Ok((out, _)) if proc.is_successful() => {
                                let _ = out;
                                page.toast(&ok_msg);
                            }
                            Ok((out, _)) => {
                                let text = out.map(|s| s.trim().to_string()).unwrap_or_default();
                                page.toast(&format!("{fail_prefix}: {text}"));
                            }
                            Err(e) => page.toast(&format!("{fail_prefix}: {e}")),
                        }
                    }
                ));
            }
            Err(_) => self.toast(&format!("{fail_prefix}: stoandl CLI not found on PATH")),
        }
    }

    // --- Watch prefs / Calendars (Step B) ------------------------------------

    fn push_watch_prefs(&self) {
        let prefs = adw::PreferencesPage::new();
        self.imp().wp_page.replace(Some(prefs.clone()));
        self.imp().wp_groups.borrow_mut().clear();
        let np = Self::nav_page("Watch settings", "watchprefs", &prefs, None);
        self.nav().push(&np);
        self.reload_watch_prefs();
    }

    fn reload_watch_prefs(&self) {
        // Cancel any pending number-write debounce before we rebuild (destroy) rows.
        if let Some(t) = self.imp().wp_debounce.borrow_mut().take() {
            t.remove();
        }
        let client = self.client();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let list = client.list_watch_prefs().await;
                // Launchable app titles for the quicklaunch picker (faces excluded).
                let titles: Vec<String> = client
                    .apps()
                    .into_iter()
                    .filter(|a| !a.is_face)
                    .map(|a| a.title)
                    .collect();
                page.imp().app_titles.replace(titles);

                let Some(prefs) = page.imp().wp_page.borrow().clone() else {
                    return;
                };
                for g in page.imp().wp_groups.borrow_mut().drain(..) {
                    prefs.remove(&g);
                }
                if list.is_empty() {
                    let g = adw::PreferencesGroup::new();
                    g.add(
                        &adw::ActionRow::builder()
                            .title("No watch settings")
                            .subtitle("Connect a watch to read and change its settings.")
                            .build(),
                    );
                    prefs.add(&g);
                    page.imp().wp_groups.borrow_mut().push(g);
                    dbg_smoke("settings: watch prefs empty");
                    return;
                }
                let mut buckets: [Vec<WatchPref>; 9] = Default::default();
                for p in list {
                    buckets[wp_section(&p.id)].push(p);
                }
                let mut total = 0;
                for (i, bucket) in buckets.iter().enumerate() {
                    if bucket.is_empty() {
                        continue;
                    }
                    let g = adw::PreferencesGroup::builder().title(&esc(WP_SECTIONS[i])).build();
                    for p in bucket {
                        let row = page.wp_row(p);
                        g.add(&row);
                        total += 1;
                    }
                    prefs.add(&g);
                    page.imp().wp_groups.borrow_mut().push(g);
                }
                dbg_smoke(&format!("settings: watch prefs loaded {total} prefs"));
            }
        ));
    }

    fn apply_pref(&self, id: &str, value: &str) {
        let client = self.client();
        let (id, value) = (id.to_string(), value.to_string());
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let s = client.set_watch_pref(&id, &value).await;
                if !s.ok() {
                    let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                    page.toast(&format!("Setting: {m}"));
                }
                page.reload_watch_prefs(); // re-fetch is authoritative
            }
        ));
    }

    fn wp_row(&self, p: &WatchPref) -> gtk::Widget {
        match p.pref_type.as_str() {
            "bool" => {
                let row = adw::SwitchRow::builder()
                    .title(&esc(&p.name))
                    .subtitle(&esc(&p.description))
                    .active(p.current_bool)
                    .build();
                let id = p.id.clone();
                row.connect_active_notify(glib::clone!(
                    #[weak(rename_to = page)]
                    self,
                    move |r| page.apply_pref(&id, if r.is_active() { "true" } else { "false" })
                ));
                row.upcast()
            }
            "enum" => {
                let model =
                    gtk::StringList::new(&p.allowed.iter().map(String::as_str).collect::<Vec<_>>());
                let row = adw::ComboRow::builder()
                    .title(&esc(&p.name))
                    .subtitle(&esc(&p.description))
                    .model(&model)
                    .build();
                row.set_selected(p.allowed.iter().position(|o| *o == p.current).unwrap_or(0) as u32);
                let (id, opts) = (p.id.clone(), p.allowed.clone());
                row.connect_selected_notify(glib::clone!(
                    #[weak(rename_to = page)]
                    self,
                    move |r| {
                        if let Some(v) = opts.get(r.selected() as usize) {
                            page.apply_pref(&id, v);
                        }
                    }
                ));
                row.upcast()
            }
            "quicklaunch" => {
                // The combo is built from ListApps titles + "Off" (the allowed field
                // is only a placeholder token); the current value stays selectable.
                let mut opts = vec!["Off".to_string()];
                opts.extend(self.imp().app_titles.borrow().iter().cloned());
                let cur = if p.current.is_empty() || p.current.eq_ignore_ascii_case("off") {
                    "Off".to_string()
                } else {
                    p.current.clone()
                };
                if !opts.iter().any(|o| *o == cur) {
                    opts.push(cur.clone());
                }
                let model =
                    gtk::StringList::new(&opts.iter().map(String::as_str).collect::<Vec<_>>());
                let row = adw::ComboRow::builder()
                    .title(&esc(&p.name))
                    .subtitle(&esc(&p.description))
                    .model(&model)
                    .build();
                row.set_selected(opts.iter().position(|o| *o == cur).unwrap_or(0) as u32);
                let id = p.id.clone();
                row.connect_selected_notify(glib::clone!(
                    #[weak(rename_to = page)]
                    self,
                    move |r| {
                        let sel = opts.get(r.selected() as usize).cloned().unwrap_or_default();
                        page.apply_pref(&id, if sel == "Off" { "off" } else { &sel });
                    }
                ));
                row.upcast()
            }
            "number" => {
                let step = (((p.max - p.min).max(1)) as f64 / 100.0).round().max(1.0);
                let val = if p.current_int >= 0 { p.current_int } else { p.min } as f64;
                let adj =
                    gtk::Adjustment::new(val, p.min as f64, p.max as f64, step, step * 10.0, 0.0);
                let row = adw::SpinRow::new(Some(&adj), step, 0);
                let title = if p.unit.is_empty() {
                    p.name.clone()
                } else {
                    format!("{} ({})", p.name, p.unit)
                };
                row.set_title(&esc(&title));
                if !p.description.is_empty() {
                    row.set_subtitle(&esc(&p.description));
                }
                // Debounce: commit ~500 ms after the user stops (the spin fires on
                // every step, and each apply re-fetches + rebuilds this control).
                // Single shared pending-write slot (one number is adjusted at a
                // time); cancelled in reload_watch_prefs so a rebuild that destroys
                // this SpinRow can't leave a stale timer to re-apply.
                let id = p.id.clone();
                adj.connect_value_changed(glib::clone!(
                    #[weak(rename_to = page)]
                    self,
                    move |a| {
                        let v = a.value().round() as i64;
                        if let Some(t) = page.imp().wp_debounce.borrow_mut().take() {
                            t.remove();
                        }
                        let id = id.clone();
                        let src = glib::timeout_add_local_once(
                            std::time::Duration::from_millis(500),
                            glib::clone!(
                                #[weak]
                                page,
                                move || {
                                    page.imp().wp_debounce.borrow_mut().take();
                                    page.apply_pref(&id, &v.to_string());
                                }
                            ),
                        );
                        page.imp().wp_debounce.borrow_mut().replace(src);
                    }
                ));
                row.upcast()
            }
            "color" => {
                let row = adw::ActionRow::builder().title(&esc(&p.name)).build();
                if !p.description.is_empty() {
                    row.set_subtitle(&esc(&p.description));
                }
                let (r, g, b) = parse_hex(&p.current);
                let swatch = gtk::DrawingArea::new();
                swatch.set_content_width(18);
                swatch.set_content_height(18);
                swatch.set_valign(gtk::Align::Center);
                swatch.set_draw_func(move |_a, cr, w, h| {
                    cr.set_source_rgb(r, g, b);
                    let rad = (w.min(h) as f64) / 2.0 - 1.0;
                    cr.arc(w as f64 / 2.0, h as f64 / 2.0, rad.max(1.0), 0.0, 2.0 * std::f64::consts::PI);
                    let _ = cr.fill();
                });
                row.add_suffix(&swatch);

                // Preset picker (allowed minus the RRGGBB free-hex placeholder).
                // Index 0 is a "Choose…" placeholder (current is a hex, not a preset).
                let mut items = vec!["Choose…".to_string()];
                items.extend(p.allowed.iter().filter(|a| *a != "RRGGBB").cloned());
                let model =
                    gtk::StringList::new(&items.iter().map(String::as_str).collect::<Vec<_>>());
                let dd = gtk::DropDown::builder().model(&model).valign(gtk::Align::Center).build();
                dd.set_selected(0);
                let id = p.id.clone();
                dd.connect_selected_notify(glib::clone!(
                    #[weak(rename_to = page)]
                    self,
                    move |d| {
                        let i = d.selected() as usize;
                        if i >= 1 {
                            if let Some(v) = items.get(i) {
                                page.apply_pref(&id, v);
                            }
                        }
                    }
                ));
                row.add_suffix(&dd);
                row.upcast()
            }
            _ => adw::ActionRow::builder()
                .title(&esc(&p.name))
                .subtitle(&esc(&p.current))
                .build()
                .upcast(),
        }
    }

    fn push_calendars(&self) {
        let prefs = adw::PreferencesPage::new();
        self.imp().cal_page.replace(Some(prefs.clone()));
        self.imp().cal_groups.borrow_mut().clear();

        // Auto-discovery master toggle (calendar.discover config).
        let discover_group = adw::PreferencesGroup::new();
        let discover = adw::SwitchRow::builder()
            .title("Auto-discover local calendars")
            .subtitle("Find the desktop's local .ics calendars (Calindori, ~/.calendars). No egress.")
            .build();
        discover.connect_active_notify(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |r| {
                if page.imp().cal_discover_on.get() == r.is_active() {
                    return; // programmatic set
                }
                page.set_discover(r.is_active());
            }
        ));
        discover_group.add(&discover);
        prefs.add(&discover_group);
        self.imp().cal_discover.replace(Some(discover));

        // Rebuild the source groups whenever the daemon re-syncs calendars.
        if !self.imp().cal_bound.replace(true) {
            self.client().connect_calendars_changed(glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_| page.rebuild_calendars()
            ));
        }

        let add = gtk::Button::from_icon_name("list-add-symbolic");
        add.set_tooltip_text(Some("Add"));
        add.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.open_source_dialog(None)
        ));
        let sync = gtk::Button::from_icon_name("view-refresh-symbolic");
        sync.set_tooltip_text(Some("Sync now"));
        sync.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.force_sync("calendar")
        ));
        let header_box = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        header_box.append(&sync);
        header_box.append(&add);

        let np = Self::nav_page("Calendars", "calendars", &prefs, Some(header_box.upcast_ref()));
        self.nav().push(&np);
        self.reload_calendars();
    }

    fn reload_calendars(&self) {
        let client = self.client();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let sources = client.list_calendar_sources().await;
                page.imp().cal_sources.replace(sources);
                let discover = client
                    .get_config()
                    .await
                    .into_iter()
                    .find(|(k, _)| k == "calendar.discover")
                    .map(|(_, v)| v == "true")
                    .unwrap_or(false);
                page.imp().cal_discover_on.set(discover);
                if let Some(sw) = page.imp().cal_discover.borrow().clone() {
                    sw.set_active(discover);
                }
                // Re-fetch calendars → emits calendars-changed → rebuild_calendars.
                client.refresh_calendars().await;
            }
        ));
    }

    fn rebuild_calendars(&self) {
        let imp = self.imp();
        let Some(prefs) = imp.cal_page.borrow().clone() else {
            return;
        };
        for g in imp.cal_groups.borrow_mut().drain(..) {
            prefs.remove(&g);
        }
        let sources = imp.cal_sources.borrow().clone();
        let calendars = self.client().calendars();

        // Group calendars by owning account.
        let mut by_account: std::collections::HashMap<String, Vec<Calendar>> =
            std::collections::HashMap::new();
        for c in &calendars {
            by_account.entry(c.account_id.clone()).or_default().push(c.clone());
        }

        if sources.is_empty() && calendars.is_empty() {
            let g = adw::PreferencesGroup::new();
            let row = adw::ActionRow::builder()
                .title("No calendars yet")
                .subtitle("Add a CalDAV account, an iCal feed URL, or a local .ics file.")
                .build();
            g.add(&row);
            prefs.add(&g);
            imp.cal_groups.borrow_mut().push(g);
            dbg_smoke("settings: calendars empty");
            return;
        }

        let mut claimed: std::collections::HashSet<String> = std::collections::HashSet::new();
        for s in &sources {
            claimed.insert(s.id.clone());
            let subtitle = if s.source_type == "caldav" && !s.username.is_empty() {
                format!("{} · {}", s.username, s.url)
            } else {
                s.url.clone()
            };
            let title = if !s.label.is_empty() {
                s.label.clone()
            } else if !s.url.is_empty() {
                s.url.clone()
            } else {
                source_type_label(&s.source_type).to_string()
            };
            let group = adw::PreferencesGroup::builder()
                .title(&esc(&title))
                .description(&esc(&subtitle))
                .build();

            // Edit + remove in the group header.
            let hb = gtk::Box::new(gtk::Orientation::Horizontal, 0);
            let icon = gtk::Image::from_icon_name(source_icon(&s.source_type));
            icon.set_valign(gtk::Align::Center);
            icon.add_css_class("dim-label");
            hb.append(&icon);
            let edit = gtk::Button::from_icon_name("document-edit-symbolic");
            edit.add_css_class("flat");
            edit.set_tooltip_text(Some("Edit"));
            let src = s.clone();
            edit.connect_clicked(glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_| page.open_source_dialog(Some(&src))
            ));
            let remove = gtk::Button::from_icon_name("user-trash-symbolic");
            remove.add_css_class("flat");
            remove.set_tooltip_text(Some("Remove"));
            let src = s.clone();
            remove.connect_clicked(glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_| page.confirm_remove_source(&src)
            ));
            hb.append(&edit);
            hb.append(&remove);
            group.set_header_suffix(Some(&hb));

            let cals = by_account.get(&s.id).cloned().unwrap_or_default();
            if cals.is_empty() {
                let hint = if s.source_type == "caldav" {
                    "No calendars found yet — if this persists, check the URL, username and password."
                } else {
                    "No calendar found at this source yet."
                };
                let row = adw::ActionRow::builder().subtitle(hint).build();
                row.add_css_class("dim-label");
                group.add(&row);
            } else {
                for c in &cals {
                    group.add(&self.calendar_toggle(c));
                }
            }
            prefs.add(&group);
            imp.cal_groups.borrow_mut().push(group);
        }

        // Discovered / orphan calendars (no owning source).
        let extras: Vec<Calendar> = by_account
            .iter()
            .filter(|(k, _)| !claimed.contains(*k))
            .flat_map(|(_, v)| v.clone())
            .collect();
        if !extras.is_empty() {
            let group = adw::PreferencesGroup::builder()
                .title("Discovered and other")
                .description(&format!("{} calendar(s)", extras.len()))
                .build();
            for c in &extras {
                group.add(&self.calendar_toggle(c));
            }
            prefs.add(&group);
            imp.cal_groups.borrow_mut().push(group);
        }
        dbg_smoke(&format!(
            "settings: calendars rebuilt {} sources, {} calendars",
            sources.len(),
            calendars.len()
        ));
    }

    fn calendar_toggle(&self, c: &Calendar) -> adw::SwitchRow {
        let row = adw::SwitchRow::builder().title(&esc(&c.name)).active(c.enabled).build();
        let id = c.id.clone();
        row.connect_active_notify(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |r| page.toggle_calendar(&id, r.is_active())
        ));
        row
    }

    fn toggle_calendar(&self, id: &str, on: bool) {
        let client = self.client();
        let id = id.to_string();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let s = client.set_calendar_enabled(&id, on).await;
                if !s.ok() {
                    let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                    page.toast(&format!("Calendar: {m}"));
                }
                client.refresh_calendars().await;
            }
        ));
    }

    fn set_discover(&self, on: bool) {
        let client = self.client();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let s = client.set_config("calendar.discover", if on { "true" } else { "false" }).await;
                if !s.ok() {
                    let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                    page.toast(&format!("Config: {m}"));
                }
                page.reload_calendars();
                page.settle_calendars();
            }
        ));
    }

    /// After a CRUD the daemon re-syncs asynchronously; the calendars-changed
    /// signal updates us, and this is the fallback — a couple of re-fetches.
    fn settle_calendars(&self) {
        for delay in [2500u32, 6000] {
            glib::timeout_add_local_once(
                std::time::Duration::from_millis(delay as u64),
                glib::clone!(
                    #[weak(rename_to = page)]
                    self,
                    move || page.reload_calendars()
                ),
            );
        }
    }

    fn confirm_remove_source(&self, src: &CalendarSource) {
        let name = if !src.label.is_empty() { &src.label } else { &src.url };
        let body = format!(
            "Remove “{name}”? Its calendars and their pins are removed from the watch. A stored CalDAV password is deleted too."
        );
        let dialog = adw::AlertDialog::new(Some("Remove calendar source"), Some(&body));
        dialog.add_response("cancel", "Cancel");
        dialog.add_response("remove", "Remove");
        dialog.set_response_appearance("remove", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let id = src.id.clone();
        dialog.connect_response(
            None,
            glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_, resp| {
                    if resp != "remove" {
                        return;
                    }
                    let client = page.client();
                    let id = id.clone();
                    glib::spawn_future_local(glib::clone!(
                        #[weak]
                        page,
                        #[strong]
                        client,
                        async move {
                            let s = client.remove_calendar_source(&id).await;
                            if !s.ok() {
                                let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                                page.toast(&format!("Remove failed: {m}"));
                            }
                            page.reload_calendars();
                            page.settle_calendars();
                        }
                    ));
                }
            ),
        );
        dialog.present(Some(self));
    }

    fn open_source_dialog(&self, edit: Option<&CalendarSource>) {
        let editing = edit.is_some();
        let init_type = edit.map(|s| s.source_type.clone()).unwrap_or_else(|| "caldav".into());

        let group = adw::PreferencesGroup::new();
        let type_row = adw::ComboRow::builder()
            .title("Type")
            .model(&gtk::StringList::new(&[
                "CalDAV account",
                "iCal feed URL",
                "Local .ics file / folder",
            ]))
            .build();
        let type_idx = match init_type.as_str() {
            "ical" => 1,
            "ics" => 2,
            _ => 0,
        };
        type_row.set_selected(type_idx);
        type_row.set_sensitive(!editing); // type is fixed on edit
        group.add(&type_row);

        let url = adw::EntryRow::builder().title("Account / feed URL or path").build();
        if let Some(s) = edit {
            url.set_text(&s.url);
        }
        group.add(&url);
        let user = adw::EntryRow::builder().title("Username").build();
        if let Some(s) = edit {
            user.set_text(&s.username);
        }
        group.add(&user);
        let pass = adw::PasswordEntryRow::builder().title("Password").build();
        if editing {
            // Password is write-only; blank = keep the current one.
            pass.set_show_apply_button(false);
        }
        group.add(&pass);

        // caldav-only fields toggle with the type.
        let update_visibility = {
            let (type_row, user, pass) = (type_row.clone(), user.clone(), pass.clone());
            std::rc::Rc::new(move || {
                let is_caldav = type_row.selected() == 0;
                user.set_visible(is_caldav);
                pass.set_visible(is_caldav);
            })
        };
        update_visibility();
        type_row.connect_selected_notify(glib::clone!(
            #[strong]
            update_visibility,
            move |_| update_visibility()
        ));

        let heading = if editing { "Edit calendar source" } else { "Add calendar" };
        let dialog = adw::AlertDialog::new(Some(heading), None);
        dialog.set_extra_child(Some(&group));
        dialog.add_response("cancel", "Cancel");
        dialog.add_response("save", "Save");
        dialog.set_response_appearance("save", adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some("save"));
        dialog.set_close_response("cancel");

        let edit_id = edit.map(|s| s.id.clone());
        dialog.connect_response(
            None,
            glib::clone!(
                #[weak(rename_to = page)]
                self,
                #[weak]
                type_row,
                #[weak]
                url,
                #[weak]
                user,
                #[weak]
                pass,
                move |_, resp| {
                    if resp != "save" {
                        return;
                    }
                    let ty = match type_row.selected() {
                        1 => "ical",
                        2 => "ics",
                        _ => "caldav",
                    }
                    .to_string();
                    let (u, un, pw) =
                        (url.text().to_string(), user.text().to_string(), pass.text().to_string());
                    let client = page.client();
                    let edit_id = edit_id.clone();
                    glib::spawn_future_local(glib::clone!(
                        #[weak]
                        page,
                        #[strong]
                        client,
                        async move {
                            let s = match &edit_id {
                                Some(id) => client.update_calendar_source(id, &u, &un, &pw).await,
                                None => client.add_calendar_source(&ty, &u, &un, &pw).await,
                            };
                            if s.ok() {
                                let where_ = match s.field(1) {
                                    "keyring" => " (saved to system keyring)",
                                    "file" => " (saved to local file — keyring unavailable)",
                                    _ => "",
                                };
                                page.toast(&format!(
                                    "{}{where_}",
                                    if edit_id.is_some() { "Calendar updated" } else { "Calendar added" }
                                ));
                                page.reload_calendars();
                                page.settle_calendars();
                            } else {
                                let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                                page.toast(&format!("Save failed: {m}"));
                            }
                        }
                    ));
                }
            ),
        );
        dialog.present(Some(self));
    }

    /// Headless smoke hook: push each sub-page so it builds/loads.
    pub fn smoke_exercise(&self) {
        if std::env::var_os("STOANDL_SMOKE_MS").is_none() {
            return;
        }
        self.push_sync();
        self.push_general();
        self.push_backup();
        self.push_watch_prefs();
        self.push_calendars();
        dbg_smoke("exercised settings sub-pages");
    }
}
