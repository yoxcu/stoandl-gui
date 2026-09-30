//! The Debug → Heartbeat page (`StoandlHeartbeatPage`) — the watch's newest
//! hourly analytics record (`native_heartbeat_record`) decoded in full. Pushed
//! from Settings → Debug as its own `NavigationPage`. Data: `HeartbeatInfo`
//! (the record header) + `HeartbeatMetrics` (every decoded metric); parsing and
//! the prefix grouping live in the client (`dbus::parse`), never here.
//!
//! Developer-facing by design: metric names are shown verbatim (and are
//! selectable, so they can be copied into a bug report), the undivided wire
//! integer rides along as the row subtitle whenever it differs from the
//! scale-divided value, and a header/summary states exactly which record was
//! decoded. When the firmware's `(size, version)` is not a layout stoandl has
//! verified, the daemon returns NO metrics rather than guessed ones — the page
//! says so prominently instead of showing an empty list.
//!
//! The daemon reads the stored record of the CONNECTED watch (it resolves the
//! watch argument among connected ones), so with none connected it answers
//! `unknown:` whatever it stored — the empty state says "no watch connected"
//! then, not "nothing captured".
//!
//! Lifecycle: a fresh page is built on every open and dropped on pop, so it just
//! loads once on `bind_client` (plus on the refresh action). The record only
//! updates hourly, so there is no poll; the one client subscription reloads when
//! a watch (dis)connects and is dropped with the page.

use std::cell::{Cell, OnceCell, RefCell};
use std::time::{SystemTime, UNIX_EPOCH};

use adw::prelude::*;
use adw::subclass::prelude::*;
use gtk::{glib, CompositeTemplate};

use super::esc;
use crate::dbus::parse::group_heartbeat_metrics;
use crate::dbus::{HeartbeatInfo, HeartbeatMetric, StoandlClient};

fn dbg_smoke(msg: &str) {
    if std::env::var_os("STOANDL_SMOKE_MS").is_some() {
        eprintln!("stoandl-smoke: {msg}");
    }
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// A metric-name prefix → its section header. Acronyms keep their casing; the
/// rest are just capitalised (the prefixes are firmware identifiers, not prose).
fn group_label(prefix: &str) -> String {
    match prefix {
        "ble" => return "BLE".into(),
        "cpu" => return "CPU".into(),
        "hrm" => return "HRM".into(),
        "pfs" => return "PFS".into(),
        "ppog" => return "PPoG".into(),
        "spi" => return "SPI".into(),
        "utc" => return "UTC".into(),
        "i2c" => return "I²C".into(),
        "fw" => return "Firmware".into(),
        "drv" => return "Drivers".into(),
        "unexpected" => return "Unexpected reboots".into(),
        "other" => return "Other".into(),
        _ => {}
    }
    let mut c = prefix.chars();
    match c.next() {
        Some(first) => first.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

/// Local wall-clock stamp of an epoch second ("—" for 0 / unparseable).
fn fmt_time(epoch: i64) -> String {
    if epoch <= 0 {
        return "—".into();
    }
    glib::DateTime::from_unix_local(epoch)
        .ok()
        .and_then(|d| d.format("%Y-%m-%d %H:%M").ok())
        .map(|g| g.to_string())
        .unwrap_or_else(|| epoch.to_string())
}

/// Our own copy plus the daemon's word on it, parenthesised — the tail of an
/// `unknown:`/`notready:` reply is a bare label ("Time 2", "battery capture
/// disabled"), so it reads as an aside, never as the whole explanation.
fn with_detail(text: &str, detail: &str) -> String {
    if detail.trim().is_empty() {
        text.to_string()
    } else {
        format!("{text} ({})", detail.trim())
    }
}

fn rel_age(epoch: i64, now: i64) -> String {
    if epoch <= 0 {
        return String::new();
    }
    let d = now - epoch;
    if d < 60 {
        "just now".into()
    } else if d < 3600 {
        format!("{}m ago", d / 60)
    } else if d < 86400 {
        format!("{}h ago", d / 3600)
    } else {
        format!("{}d ago", d / 86400)
    }
}

mod imp {
    use super::*;

    #[derive(CompositeTemplate, Default)]
    #[template(resource = "/de/yoxcu/stoandl/gui/ui/heartbeat.ui")]
    pub struct StoandlHeartbeatPage {
        #[template_child]
        pub refresh_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub search_button: TemplateChild<gtk::ToggleButton>,
        #[template_child]
        pub search_bar: TemplateChild<gtk::SearchBar>,
        #[template_child]
        pub search_entry: TemplateChild<gtk::SearchEntry>,
        #[template_child]
        pub heartbeat_stack: TemplateChild<gtk::Stack>,
        #[template_child]
        pub empty_status: TemplateChild<adw::StatusPage>,
        #[template_child]
        pub prefs_page: TemplateChild<adw::PreferencesPage>,
        #[template_child]
        pub warn_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub summary_group: TemplateChild<adw::PreferencesGroup>,

        pub client: OnceCell<StoandlClient>,

        // Latest snapshot: the record header, the reply kind/tail (so the empty
        // state can tell `unknown:` from `notready:`), and the decoded metrics.
        pub info: RefCell<Option<HeartbeatInfo>>,
        pub kind: RefCell<String>,
        pub detail: RefCell<String>,
        pub metrics: RefCell<Vec<HeartbeatMetric>>,
        pub filter: RefCell<String>,

        // Dynamically built widgets (removed on each rebuild).
        pub summary_rows: RefCell<Vec<gtk::Widget>>,
        pub metric_groups: RefCell<Vec<adw::PreferencesGroup>>,

        pub reload_gen: Cell<u64>,

        // watches-changed subscription (+ the connected state it last saw), dropped in dispose.
        pub watches_handler: RefCell<Option<glib::SignalHandlerId>>,
        pub watch_connected: Cell<bool>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for StoandlHeartbeatPage {
        const NAME: &'static str = "StoandlHeartbeatPage";
        type Type = super::StoandlHeartbeatPage;
        type ParentType = adw::NavigationPage;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }
        fn instance_init(obj: &glib::subclass::InitializingObject<Self>) {
            obj.init_template();
        }
    }

    impl ObjectImpl for StoandlHeartbeatPage {
        fn dispose(&self) {
            if let (Some(c), Some(id)) = (self.client.get(), self.watches_handler.take()) {
                c.disconnect(id);
            }
        }
    }
    impl WidgetImpl for StoandlHeartbeatPage {}
    impl NavigationPageImpl for StoandlHeartbeatPage {}
}

glib::wrapper! {
    pub struct StoandlHeartbeatPage(ObjectSubclass<imp::StoandlHeartbeatPage>)
        @extends adw::NavigationPage, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl Default for StoandlHeartbeatPage {
    fn default() -> Self {
        Self::new()
    }
}

impl StoandlHeartbeatPage {
    pub fn new() -> Self {
        glib::Object::new()
    }

    fn client(&self) -> StoandlClient {
        self.imp().client.get().expect("client bound").clone()
    }

    /// Store the client, wire the refresh + filter chrome, kick the one load.
    pub fn bind_client(&self, client: &StoandlClient) {
        let imp = self.imp();
        imp.client.set(client.clone()).ok();

        imp.refresh_button.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.spawn_reload()
        ));

        // Header toggle ⇄ search bar, and typing on the page opens it.
        imp.search_button
            .bind_property("active", &imp.search_bar.get(), "search-mode-enabled")
            .bidirectional()
            .sync_create()
            .build();
        imp.search_bar.connect_entry(&imp.search_entry.get());
        imp.search_bar.set_key_capture_widget(Some(self));
        imp.search_entry.connect_search_changed(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |e| page.set_filter(&e.text())
        ));

        // A (re)connect makes the connected watch's record readable, a disconnect unreadable.
        imp.watch_connected.set(client.connected_watch().is_some());
        let id = client.connect_watches_changed(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |c| {
                let now = c.connected_watch().is_some();
                if page.imp().watch_connected.replace(now) != now {
                    page.spawn_reload();
                }
            }
        ));
        imp.watches_handler.replace(Some(id));

        self.spawn_reload();
    }

    fn set_filter(&self, text: &str) {
        let text = text.trim().to_lowercase();
        if *self.imp().filter.borrow() == text {
            return;
        }
        self.imp().filter.replace(text);
        self.rebuild_metrics();
    }

    fn spawn_reload(&self) {
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            async move { page.reload().await }
        ));
    }

    async fn reload(&self) {
        let generation = self.imp().reload_gen.get().wrapping_add(1);
        self.imp().reload_gen.set(generation);
        let c = self.client();

        if !c.daemon_up() {
            self.imp().info.replace(None);
            self.imp().kind.replace(String::new());
            self.imp().detail.replace(String::new());
            self.imp().metrics.replace(Vec::new());
            self.update_ui();
            return;
        }

        let (status, info) = c.heartbeat_info("").await;
        // An unverified layout yields no metrics by contract — don't ask for them.
        let metrics = if info.as_ref().is_some_and(|i| i.known) {
            c.heartbeat_metrics("").await
        } else {
            Vec::new()
        };

        // A newer reload superseded us while awaiting — drop this stale snapshot.
        if self.imp().reload_gen.get() != generation {
            return;
        }

        self.imp().kind.replace(status.kind.clone());
        self.imp().detail.replace(status.tail.clone());
        self.imp().info.replace(info);
        self.imp().metrics.replace(metrics);
        self.update_ui();
    }

    // --- update ---------------------------------------------------------------

    fn update_ui(&self) {
        let imp = self.imp();
        let up = self.client().daemon_up();
        let info = imp.info.borrow().clone();

        imp.refresh_button.set_sensitive(up);
        imp.heartbeat_stack
            .set_visible_child_name(if info.is_some() { "content" } else { "empty" });

        let Some(info) = info else {
            let kind = imp.kind.borrow().clone();
            let detail = imp.detail.borrow().clone();
            let (icon, title, desc) = if !up {
                (
                    "dialog-information-symbolic",
                    "Daemon not running",
                    "Start it with: systemctl --user reset-failed stoandl; systemctl --user start stoandl"
                        .to_string(),
                )
            } else if kind == "notready" {
                (
                    "dialog-information-symbolic",
                    "Heartbeat capture is off",
                    with_detail(
                        "stoandl is not decoding the watch’s analytics records, so there is nothing \
                         to show. Turn “Battery insights” back on in Settings → Daemon configuration.",
                        &detail,
                    ),
                )
            } else if kind == "unknown" && self.client().connected_watch().is_none() {
                (
                    "dialog-information-symbolic",
                    "No watch connected",
                    "stoandl shows the newest heartbeat of the connected watch. Connect it to see \
                     its record."
                        .to_string(),
                )
            } else if kind == "unknown" {
                (
                    "dialog-information-symbolic",
                    "No heartbeat captured yet",
                    with_detail(
                        "The watch emits one analytics record about once an hour while it is \
                         connected. None has arrived yet.",
                        &detail,
                    ),
                )
            } else {
                (
                    "dialog-warning-symbolic",
                    "Could not read the heartbeat",
                    if detail.is_empty() { kind.clone() } else { detail.clone() },
                )
            };
            imp.empty_status.set_icon_name(Some(icon));
            imp.empty_status.set_title(title);
            imp.empty_status.set_description(Some(&esc(&desc)));
            // Nothing to filter without a list.
            imp.search_button.set_visible(false);
            imp.search_bar.set_search_mode(false);
            self.clear_metric_groups();
            dbg_smoke(&format!("heartbeat ui: empty (up={up}, kind={kind}, title={title:?})"));
            return;
        };

        // Unverified layout: the record IS captured, it is just not decoded.
        imp.warn_group.set_visible(!info.known);
        if !info.known {
            imp.warn_group.set_description(Some(&format!(
                "This firmware’s heartbeat record — {} bytes, layout v{} — is not one stoandl has \
                 verified against PebbleOS. The record is still captured and stored raw, but no \
                 metrics are listed: stoandl never shows guessed values.",
                info.size, info.version
            )));
        }

        self.rebuild_summary(&info);

        let count = imp.metrics.borrow().len();
        imp.search_button.set_visible(count > 0);
        if count == 0 {
            imp.search_bar.set_search_mode(false);
        }
        self.rebuild_metrics();

        dbg_smoke(&format!(
            "heartbeat ui: size={}B v{}, known={}, fw={:?}, metrics={count}",
            info.size, info.version, info.known, info.firmware
        ));
    }

    fn rebuild_summary(&self, info: &HeartbeatInfo) {
        let imp = self.imp();
        for w in imp.summary_rows.borrow_mut().drain(..) {
            imp.summary_group.remove(&w);
        }
        let now = now_secs();

        let recorded_sub = if info.watch_ts > 0 {
            rel_age(info.watch_ts, now)
        } else {
            "the record carries no watch clock".to_string()
        };
        let rows = [
            fact_row("Recorded", &recorded_sub, &fmt_time(info.watch_ts), false),
            fact_row("Received", &rel_age(info.rx_ts, now), &fmt_time(info.rx_ts), false),
            fact_row("Size", "", &format!("{} bytes", info.size), false),
            fact_row(
                "Layout version",
                if info.known { "verified against PebbleOS" } else { "not verified" },
                &format!("v{}", info.version),
                false,
            ),
            fact_row("Firmware", "", &info.firmware, false),
            fact_row(
                "Build ID",
                "firmware GNU build-id, not a git commit",
                &info.build_id,
                true,
            ),
            fact_row("Metrics", "", &info.metric_count.to_string(), false),
        ];
        for row in rows {
            imp.summary_group.add(&row);
            imp.summary_rows.borrow_mut().push(row.upcast());
        }
    }

    fn clear_metric_groups(&self) {
        let imp = self.imp();
        for g in imp.metric_groups.borrow_mut().drain(..) {
            imp.prefs_page.remove(&g);
        }
    }

    /// Rebuild the metric list: one `PreferencesGroup` per name prefix, in the
    /// daemon's record order, filtered by the search text (matched on the name).
    fn rebuild_metrics(&self) {
        let imp = self.imp();
        self.clear_metric_groups();

        let metrics = imp.metrics.borrow().clone();
        // The unverified-layout case is explained by warn_group — no placeholder.
        let known = imp.info.borrow().as_ref().is_some_and(|i| i.known);
        if metrics.is_empty() {
            if known {
                let g = note_group(
                    "No metrics in this record",
                    "The heartbeat was captured but carried no decoded metrics.",
                );
                imp.prefs_page.add(&g);
                imp.metric_groups.borrow_mut().push(g);
            }
            return;
        }

        let filter = imp.filter.borrow().clone();
        let matching: Vec<HeartbeatMetric> = metrics
            .into_iter()
            .filter(|m| filter.is_empty() || m.name.to_lowercase().contains(&filter))
            .collect();
        if matching.is_empty() {
            let g = note_group("No matching metrics", "No metric name contains that text.");
            imp.prefs_page.add(&g);
            imp.metric_groups.borrow_mut().push(g);
            return;
        }

        for (prefix, rows) in group_heartbeat_metrics(&matching) {
            let group = adw::PreferencesGroup::builder()
                .title(&esc(&group_label(&prefix)))
                .build();
            for m in &rows {
                group.add(&metric_row(m));
            }
            imp.prefs_page.add(&group);
            imp.metric_groups.borrow_mut().push(group);
        }
    }

    /// Headless smoke hook: open the filter and type into it, so the search →
    /// regroup path renders too. No-op outside the smoke test.
    pub fn smoke_exercise(&self) {
        if std::env::var_os("STOANDL_SMOKE_MS").is_none() {
            return;
        }
        self.imp().search_button.set_active(true);
        self.imp().search_entry.set_text("battery");
        dbg_smoke("exercised heartbeat filter");
    }
}

// --- small widget builders ---------------------------------------------------

/// A label/value fact row: right-aligned value ("—" when empty), optional dim
/// subtitle. `mono` marks the copy-worthy ones (the build id).
fn fact_row(label: &str, subtitle: &str, value: &str, mono: bool) -> adw::ActionRow {
    let row = adw::ActionRow::builder().title(label).build();
    if !subtitle.is_empty() {
        row.set_subtitle(&esc(subtitle));
    }
    let shown = if value.trim().is_empty() { "—" } else { value };
    let vl = gtk::Label::builder()
        .label(shown)
        .xalign(1.0)
        .selectable(mono)
        .ellipsize(gtk::pango::EllipsizeMode::End)
        .max_width_chars(30)
        .tooltip_text(shown) // a build id is longer than the row can show
        .build();
    if mono {
        vl.add_css_class("mono");
    } else {
        vl.add_css_class("dim-label");
    }
    row.add_suffix(&vl);
    row
}

/// One metric: the firmware's own name (selectable — devs copy it), the value
/// (`text` for the string metrics, else the scale-divided number), and the
/// undivided wire integer as a subtitle whenever it differs from that value.
fn metric_row(m: &HeartbeatMetric) -> adw::ActionRow {
    let row = adw::ActionRow::builder().title(&esc(&m.name)).build();
    row.set_title_selectable(true);
    if !m.raw.is_empty() && m.raw != m.value {
        row.set_subtitle(&esc(&format!("raw {}", m.raw)));
    }
    let shown = if m.display.trim().is_empty() { "—" } else { m.display.as_str() };
    let vl = gtk::Label::builder()
        .label(shown)
        .xalign(1.0)
        .selectable(true)
        .ellipsize(gtk::pango::EllipsizeMode::End)
        .max_width_chars(30)
        .tooltip_text(shown) // a watchface uuid is longer than the row can show
        .build();
    vl.add_css_class("mono");
    row.add_suffix(&vl);
    row
}

/// An inline "nothing here" group (used for an empty / filtered-out metric list).
fn note_group(title: &str, subtitle: &str) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::new();
    let row = adw::ActionRow::builder().title(title).subtitle(subtitle).build();
    row.add_css_class("dim-label");
    group.add(&row);
    group
}
