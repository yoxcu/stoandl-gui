//! The Notifications tab (`StoandlNotificationsPage`) — port of
//! `qml/NotificationsPage.qml`. Master forward toggle (via sync-status) + a
//! temporary mute + where the app name goes on the watch (`notification.app_name`,
//! with a watch-card preview), a per-app list (each row opens a deeper dialog for
//! on/off, temp-mute, colour, vibration, icon + the app's own app-name choice, with
//! the same preview), and regex allow/block filters. No change signals — every
//! mutation re-fetches (reload), and so does showing the page, since the global
//! app-name key is also on Settings → Daemon configuration.

use std::cell::{Cell, OnceCell, RefCell};

use adw::prelude::*;
use adw::subclass::prelude::*;
use gtk::{glib, CompositeTemplate};

use super::esc;
use crate::dbus::{NotifApp, NotifFilter, StoandlClient};
use crate::widgets::watch_preview::WatchPreview;
use crate::window::StoandlWindow;

const VIBES: [&str; 5] = ["Standard", "Double", "Long", "Subtle", "Heartbeat"];
const ICONS: [&str; 4] = ["Default", "Bell", "Calendar", "Chat"];

/// Curated subset of the watch's TimelineColor palette. `.0` = display name, `.1` =
/// the enum name the daemon stores (NotifSetStyle takes a name, not a hex; NotifList
/// ships no allowed set, so it's hardcoded), `.2` = the swatch RGB (None = "default",
/// no override). Mirrors NotificationsPage.qml colorOptions (same names, values, hexes).
const COLORS: [(&str, &str, Option<(f64, f64, f64)>); 8] = [
    ("Default", "default", None),
    ("Red", "Red", Some((1.0, 0.0, 0.0))),
    ("Orange", "Orange", Some((1.0, 0.333, 0.0))), // #FF5500
    ("Yellow", "ChromeYellow", Some((1.0, 0.667, 0.0))), // #FFAA00
    ("Green", "Green", Some((0.0, 1.0, 0.0))),
    ("Cyan", "Cyan", Some((0.0, 1.0, 1.0))),
    ("Blue", "BlueMoon", Some((0.0, 0.333, 1.0))), // #0055FF
    ("Violet", "VividViolet", Some((0.667, 0.0, 1.0))), // #AA00FF
];

/// The app's override of `notification.app_name`. `.0` = display name, `.1` = what
/// NotifSetAppName takes (`default` drops the override, so the app follows the global
/// key and NotifList's app-name column is empty). Mirrors NotificationsPage.qml appNameOptions.
const APP_NAMES: [(&str, &str); 4] =
    [("Default", "default"), ("Small line", "small"), ("Subtitle", "subtitle"), ("Off", "off")];

/// Index into [`APP_NAMES`] for a NotifList app-name token (case-insensitive, like the daemon);
/// empty (no override) → Default.
fn app_name_index(token: &str) -> usize {
    APP_NAMES.iter().position(|(_, v)| v.eq_ignore_ascii_case(token)).unwrap_or(0)
}

/// The global setting the per-app choice overrides. Its choices are [`APP_NAMES`] without Default,
/// whose labels are the daemon's combo labels: what GetConfig reports and SetConfig takes back.
const APP_NAME_KEY: &str = "notification.app_name";

/// The placement token for a GetConfig value of [`APP_NAME_KEY`] (a label; a bare token works too).
fn app_name_token(value: &str) -> Option<&'static str> {
    APP_NAMES[1..]
        .iter()
        .find(|(label, token)| label.eq_ignore_ascii_case(value) || token.eq_ignore_ascii_case(value))
        .map(|(_, token)| *token)
}

/// The app the Alerts page's preview shows.
const SAMPLE_APP: &str = "NeoChat";

/// What a preview shows, for the smoke log: `preview <placement>: title=… | small=… | …`.
fn dbg_preview(preview: &WatchPreview) {
    dbg_smoke(&format!("preview {}: {}", preview.placement(), preview.summary()));
}

fn dbg_smoke(msg: &str) {
    if std::env::var_os("STOANDL_SMOKE_MS").is_some() {
        eprintln!("stoandl-smoke: {msg}");
    }
}

/// The master temporary-mute row (title + the duration/resume buttons).
#[derive(Clone)]
pub struct MuteRow {
    row: adw::ActionRow,
    resume: gtk::Button,
    b30: gtk::Button,
    b1h: gtk::Button,
    today: gtk::Button,
}

mod imp {
    use super::*;

    #[derive(CompositeTemplate, Default)]
    #[template(resource = "/de/yoxcu/stoandl/gui/ui/notifications.ui")]
    pub struct StoandlNotificationsPage {
        #[template_child]
        pub add_filter_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub send_test_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub forward_switch: TemplateChild<adw::SwitchRow>,
        #[template_child]
        pub forwarding_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub perapp_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub filters_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub view_switcher: TemplateChild<adw::ViewSwitcher>,
        #[template_child]
        pub switcher_bar: TemplateChild<adw::ViewSwitcherBar>,

        pub client: OnceCell<StoandlClient>,
        pub updating: Cell<bool>, // guards programmatic forward_switch sets
        pub reload_gen: Cell<u64>, // drops stale reloads that would rebuild from an old snapshot
        pub apps: RefCell<Vec<NotifApp>>,
        pub filters: RefCell<Vec<NotifFilter>>,
        pub perapp_rows: RefCell<Vec<gtk::Widget>>,
        pub filter_rows: RefCell<Vec<gtk::Widget>>,
        pub mute: OnceCell<MuteRow>,
        pub app_name_row: OnceCell<adw::ComboRow>,
        pub preview: OnceCell<WatchPreview>,
        /// `notification.app_name` as last read; None until then (or from a daemon without the key).
        pub global_app_name: Cell<Option<&'static str>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for StoandlNotificationsPage {
        const NAME: &'static str = "StoandlNotificationsPage";
        type Type = super::StoandlNotificationsPage;
        type ParentType = adw::BreakpointBin;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }
        fn instance_init(obj: &glib::subclass::InitializingObject<Self>) {
            obj.init_template();
        }
    }

    impl ObjectImpl for StoandlNotificationsPage {}
    impl WidgetImpl for StoandlNotificationsPage {}
    impl BreakpointBinImpl for StoandlNotificationsPage {}
}

glib::wrapper! {
    pub struct StoandlNotificationsPage(ObjectSubclass<imp::StoandlNotificationsPage>)
        @extends adw::BreakpointBin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl Default for StoandlNotificationsPage {
    fn default() -> Self {
        Self::new()
    }
}

impl StoandlNotificationsPage {
    pub fn new() -> Self {
        glib::Object::new()
    }

    /// Point this page's in-header view switcher (and its narrow bottom bar) at
    /// the shell view stack (the stack lives in the window template).
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

    pub fn bind_client(&self, client: &StoandlClient) {
        self.imp().client.set(client.clone()).ok();
        self.build_mute_row();
        self.build_app_name_row();

        self.imp().add_filter_button.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.open_add_filter()
        ));
        self.imp().send_test_button.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.send_test()
        ));
        // Master forward toggle (guarded against programmatic sets in update).
        self.imp().forward_switch.connect_active_notify(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |sw| {
                if page.imp().updating.get() {
                    return;
                }
                let on = sw.is_active();
                let client = page.client();
                glib::spawn_future_local(glib::clone!(
                    #[weak]
                    page,
                    #[strong]
                    client,
                    async move {
                        let s = client.set_sync_enabled("notifications", on).await;
                        if s.ok() {
                            page.toast(if on { "Notifications on" } else { "Notifications paused" });
                        } else {
                            let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                            page.toast(&format!("Could not change forwarding: {m}"));
                        }
                        page.reload().await;
                    }
                ));
            }
        ));
        client.connect_notify_local(
            Some("daemon-up"),
            glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |c, _| {
                    if c.daemon_up() {
                        page.spawn_reload();
                    }
                }
            ),
        );

        // The pages outlive a tab switch here (Kirigami rebuilds its page on each one), so re-read when
        // shown: the app-name key can have changed on Settings → Daemon configuration meanwhile.
        self.connect_map(|page| page.spawn_reload());

        self.spawn_reload();
    }

    fn spawn_reload(&self) {
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            async move { page.reload().await }
        ));
    }

    async fn reload(&self) {
        let generation = self.imp().reload_gen.get() + 1;
        self.imp().reload_gen.set(generation);
        let c = self.client();
        if !c.daemon_up() {
            return;
        }
        let forward = c
            .get_sync_status()
            .await
            .iter()
            .find(|s| s.service == "notifications")
            .map(|s| s.enabled)
            .unwrap_or(false);
        let apps = c.notif_list().await;
        let filters = c.notif_list_filters().await;
        let app_name = c
            .get_config()
            .await
            .into_iter()
            .find(|(k, _)| k == APP_NAME_KEY)
            .and_then(|(_, v)| app_name_token(&v));

        // A newer mutation+reload superseded us while awaiting — don't rebuild the
        // per-app rows from this stale snapshot (it could revert a just-set switch).
        if self.imp().reload_gen.get() != generation {
            return;
        }
        *self.imp().apps.borrow_mut() = apps;
        *self.imp().filters.borrow_mut() = filters;
        self.imp().global_app_name.set(app_name);
        self.update_ui(forward);
    }

    fn all_muted(&self) -> bool {
        let apps = self.imp().apps.borrow();
        !apps.is_empty() && apps.iter().all(|a| a.muted)
    }

    fn update_ui(&self, forward: bool) {
        let imp = self.imp();
        // Guarded sets so they don't re-trigger the handlers.
        imp.updating.set(true);
        imp.forward_switch.set_active(forward);
        let global = imp.global_app_name.get();
        if let (Some(row), Some(preview)) = (imp.app_name_row.get(), imp.preview.get()) {
            row.set_visible(global.is_some());
            preview.widget().set_visible(global.is_some());
            if let Some(token) = global {
                row.set_selected(app_name_index(token).saturating_sub(1) as u32);
                preview.set_placement(token);
            }
        }
        imp.updating.set(false);

        // Temporary mute row.
        if let Some(m) = imp.mute.get() {
            let all_muted = self.all_muted();
            m.row
                .set_title(if all_muted { "Muted temporarily" } else { "Mute temporarily" });
            m.resume.set_visible(all_muted);
            m.b30.set_visible(!all_muted);
            m.b1h.set_visible(!all_muted);
            m.today.set_visible(!all_muted);
        }

        self.rebuild_perapp();
        self.rebuild_filters();
    }

    // --- master temporary mute -----------------------------------------------

    fn build_mute_row(&self) {
        let row = adw::ActionRow::builder().title("Mute temporarily").build();
        let bx = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        bx.set_valign(gtk::Align::Center);
        let resume = gtk::Button::from_icon_name("media-playback-start-symbolic");
        resume.set_tooltip_text(Some("Resume now"));
        let b30 = gtk::Button::with_label("30 min");
        let b1h = gtk::Button::with_label("1 hr");
        let today = gtk::Button::with_label("Today");
        for b in [&resume, &b30, &b1h, &today] {
            b.add_css_class("flat");
        }
        bx.append(&resume);
        bx.append(&b30);
        bx.append(&b1h);
        bx.append(&today);
        row.add_suffix(&bx);
        self.imp().forwarding_group.add(&row);

        resume.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.mute_all("never")
        ));
        b30.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.mute_all("30m")
        ));
        b1h.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.mute_all("1h")
        ));
        today.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.mute_all("today")
        ));

        self.imp().mute.set(MuteRow { row, resume, b30, b1h, today }).ok();
    }

    fn mute_all(&self, spec: &str) {
        let client = self.client();
        let spec = spec.to_string();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let s = client.notif_set_mute_all(&spec).await;
                if s.ok() {
                    page.toast(match spec.as_str() {
                        "never" => "Notifications resumed".to_string(),
                        "today" => "Muted for the rest of today".to_string(),
                        other => format!("Muted for {other}"),
                    }
                    .as_str());
                } else {
                    let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                    page.toast(&format!("Mute failed: {m}"));
                }
                page.reload().await;
            }
        ));
    }

    // --- global app-name placement ---------------------------------------------

    /// `notification.app_name`, the key of the same row on Settings → Daemon configuration, with a
    /// preview of the card under it. Both stay hidden until a reload has read the key, so a daemon
    /// without it shows neither.
    fn build_app_name_row(&self) {
        let labels: Vec<&str> = APP_NAMES[1..].iter().map(|(label, _)| *label).collect();
        let row = adw::ComboRow::builder()
            .title("App name on the watch")
            .subtitle("Where an app's name goes on a notification. Each app can override it.")
            .model(&gtk::StringList::new(&labels))
            .visible(false)
            .build();
        let preview = WatchPreview::new(SAMPLE_APP);
        preview.widget().set_visible(false);
        row.connect_selected_notify(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            preview,
            move |r| {
                if page.imp().updating.get() {
                    return;
                }
                let Some(&(label, token)) = APP_NAMES[1..].get(r.selected() as usize) else {
                    return;
                };
                page.imp().global_app_name.set(Some(token));
                preview.set_placement(token);
                page.set_global_app_name(label);
            }
        ));
        self.imp().forwarding_group.add(&row);
        self.imp().forwarding_group.add(preview.widget()); // not a row: goes under the list
        self.imp().app_name_row.set(row).ok();
        self.imp().preview.set(preview).ok();
    }

    fn set_global_app_name(&self, label: &str) {
        let client = self.client();
        let label = label.to_string();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let s = client.set_config(APP_NAME_KEY, &label).await;
                if s.ok() {
                    page.toast(&format!("App name · {label}"));
                } else {
                    let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                    page.toast(&format!("App name: {m}"));
                }
                page.reload().await;
            }
        ));
    }

    /// The placement an [`APP_NAMES`] choice shows: its own, or for Default the global one (the
    /// daemon's default, the small line, until a reload has read it).
    fn app_name_placement(&self, idx: usize) -> &'static str {
        match APP_NAMES.get(idx) {
            Some(&(_, token)) if token != "default" => token,
            _ => self.imp().global_app_name.get().unwrap_or("small"),
        }
    }

    // --- per-app list ---------------------------------------------------------

    fn rebuild_perapp(&self) {
        let imp = self.imp();
        for w in imp.perapp_rows.borrow_mut().drain(..) {
            imp.perapp_group.remove(&w);
        }
        let apps = imp.apps.borrow().clone();
        imp.perapp_group.set_visible(!apps.is_empty());
        for a in &apps {
            let row = self.perapp_row(a);
            imp.perapp_group.add(&row);
            imp.perapp_rows.borrow_mut().push(row.upcast());
        }
        dbg_smoke(&format!("notif rebuild: {} apps, all_muted={}", apps.len(), self.all_muted()));
    }

    fn perapp_row(&self, app: &NotifApp) -> adw::ActionRow {
        let subtitle = if app.muted {
            "Muted".to_string()
        } else {
            format!("Vibration · {}", app.vibe)
        };
        let row = adw::ActionRow::builder()
            .title(&esc(&app.name))
            .subtitle(&esc(&subtitle))
            .activatable(true)
            .build();
        let icon = gtk::Image::from_icon_name("preferences-system-notifications-symbolic");
        if !app.muted {
            icon.add_css_class("accent");
        }
        row.add_prefix(&icon);

        // On = NOT muted. Set before connecting so no spurious toggle.
        let sw = gtk::Switch::new();
        sw.set_valign(gtk::Align::Center);
        sw.set_active(!app.muted);
        let name = app.name.clone();
        sw.connect_active_notify(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |s| page.set_app_mute(&name, if s.is_active() { "never" } else { "always" })
        ));
        row.add_suffix(&sw);

        let chevron = gtk::Image::from_icon_name("go-next-symbolic");
        chevron.add_css_class("dim-label");
        row.add_suffix(&chevron);

        let app = app.clone();
        row.connect_activated(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| {
                page.open_app_dialog(&app);
            }
        ));
        row
    }

    fn set_app_mute(&self, name: &str, spec: &str) {
        let client = self.client();
        let name = name.to_string();
        let spec = spec.to_string();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let s = client.notif_set_mute(&name, &spec).await;
                if !s.ok() {
                    let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                    page.toast(&format!("Mute failed: {m}"));
                }
                page.reload().await;
            }
        ));
    }

    fn set_app_style(&self, name: &str, color: &str, icon: &str, vibe: &str, toast: String) {
        let client = self.client();
        let (name, color, icon, vibe) =
            (name.to_string(), color.to_string(), icon.to_string(), vibe.to_string());
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let s = client.notif_set_style(&name, &color, &icon, &vibe).await;
                if s.ok() {
                    page.toast(&toast);
                } else {
                    let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                    page.toast(&format!("Style: {m}"));
                }
                page.reload().await;
            }
        ));
    }

    fn set_app_name(&self, name: &str, label: &str, placement: &str) {
        let client = self.client();
        let (name, label, placement) = (name.to_string(), label.to_string(), placement.to_string());
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let s = client.notif_set_app_name(&name, &placement).await;
                if s.ok() {
                    page.toast(&format!("App name · {label}"));
                } else {
                    let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                    page.toast(&format!("App name: {m}"));
                }
                page.reload().await;
            }
        ));
    }

    fn open_app_dialog(&self, app: &NotifApp) -> (adw::Dialog, WatchPreview) {
        let prefs = adw::PreferencesPage::new();

        // On/off + temporary mute. All buttons are built once; a local `muted`
        // state + a guarded re-render (the QML refreshApp() analogue) keeps the
        // on/off subtitle and the Resume-vs-durations buttons live after an
        // in-dialog mutation, instead of going stale.
        let g1 = adw::PreferencesGroup::new();
        let on = adw::SwitchRow::builder().title("Notifications").build();
        g1.add(&on);

        let mute_row = adw::ActionRow::new();
        let bx = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        bx.set_valign(gtk::Align::Center);
        let resume = gtk::Button::with_label("Resume");
        let b30 = gtk::Button::with_label("30 min");
        let b1h = gtk::Button::with_label("1 hr");
        let today = gtk::Button::with_label("Today");
        for b in [&resume, &b30, &b1h, &today] {
            b.add_css_class("flat");
            bx.append(b);
        }
        mute_row.add_suffix(&bx);
        g1.add(&mute_row);
        prefs.add(&g1);

        let muted = std::rc::Rc::new(Cell::new(app.muted));
        let dlg_updating = std::rc::Rc::new(Cell::new(false));
        let apply = {
            let (on, mute_row) = (on.clone(), mute_row.clone());
            let (resume, b30, b1h, today) =
                (resume.clone(), b30.clone(), b1h.clone(), today.clone());
            let (muted, dlg_updating) = (muted.clone(), dlg_updating.clone());
            std::rc::Rc::new(move || {
                let m = muted.get();
                dlg_updating.set(true);
                on.set_active(!m);
                dlg_updating.set(false);
                on.set_subtitle(if m { "Off" } else { "Forwarded to watch" });
                mute_row.set_title(if m { "Muted" } else { "Mute temporarily" });
                resume.set_visible(m);
                b30.set_visible(!m);
                b1h.set_visible(!m);
                today.set_visible(!m);
            })
        };
        apply();

        {
            let name = app.name.clone();
            let (muted, dlg_updating, apply) = (muted.clone(), dlg_updating.clone(), apply.clone());
            on.connect_active_notify(glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |s| {
                    if dlg_updating.get() {
                        return;
                    }
                    let active = s.is_active();
                    muted.set(!active);
                    apply();
                    page.set_app_mute(&name, if active { "never" } else { "always" });
                }
            ));
        }
        {
            let name = app.name.clone();
            let (muted, apply) = (muted.clone(), apply.clone());
            resume.connect_clicked(glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_| {
                    muted.set(false);
                    apply();
                    page.set_app_mute(&name, "never");
                }
            ));
        }
        for (btn, spec) in [(&b30, "30m"), (&b1h, "1h"), (&today, "today")] {
            let name = app.name.clone();
            let spec = spec.to_string();
            let (muted, apply) = (muted.clone(), apply.clone());
            btn.connect_clicked(glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_| {
                    muted.set(true);
                    apply();
                    page.set_app_mute(&name, &spec);
                }
            ));
        }

        // Colour + vibration + icon + app name, and a preview of the card with the colour and app name.
        let g2 = adw::PreferencesGroup::new();
        let preview = WatchPreview::new(&app.name);

        let color_labels: Vec<&str> = COLORS.iter().map(|(t, _, _)| *t).collect();
        let color_model = gtk::StringList::new(&color_labels);
        let color_row = adw::ComboRow::builder()
            .title("Notification color")
            .subtitle("Accent colour on the watch")
            .model(&color_model)
            .build();
        let sel0 =
            COLORS.iter().position(|(_, v, _)| v.eq_ignore_ascii_case(&app.color)).unwrap_or(0);
        color_row.set_selected(sel0 as u32);
        preview.set_color(COLORS[sel0].2);

        // A swatch prefix reflecting the current selection (the QML showed a colour
        // per option); "default" draws a themed outline ring, not a fill.
        let swatch = gtk::DrawingArea::new();
        swatch.set_content_width(18);
        swatch.set_content_height(18);
        swatch.set_valign(gtk::Align::Center);
        let sel = std::rc::Rc::new(std::cell::Cell::new(sel0));
        swatch.set_draw_func(glib::clone!(
            #[strong]
            sel,
            move |a, cr, w, h| {
                let rad = ((w.min(h) as f64) / 2.0 - 1.0).max(1.0);
                cr.arc(w as f64 / 2.0, h as f64 / 2.0, rad, 0.0, 2.0 * std::f64::consts::PI);
                match COLORS[sel.get()].2 {
                    Some((r, g, b)) => {
                        cr.set_source_rgb(r, g, b);
                        let _ = cr.fill();
                    }
                    None => {
                        let c = a.color(); // themed foreground → no hardcoded colour
                        cr.set_source_rgba(c.red() as f64, c.green() as f64, c.blue() as f64, 0.4);
                        cr.set_line_width(1.5);
                        let _ = cr.stroke();
                    }
                }
            }
        ));
        color_row.add_prefix(&swatch);

        let name = app.name.clone();
        color_row.connect_selected_notify(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[weak]
            swatch,
            #[strong]
            sel,
            #[strong]
            preview,
            move |r| {
                let idx = r.selected() as usize;
                sel.set(idx);
                swatch.queue_draw();
                let (text, value, rgb) =
                    COLORS.get(idx).copied().unwrap_or(("Default", "default", None));
                preview.set_color(rgb);
                page.set_app_style(&name, value, "", "", format!("Color · {text}"));
            }
        ));
        g2.add(&color_row);

        let vibe_model = gtk::StringList::new(&VIBES);
        let vibe_row = adw::ComboRow::builder().title("Vibration").model(&vibe_model).build();
        vibe_row.set_selected(VIBES.iter().position(|v| *v == app.vibe).unwrap_or(0) as u32);
        let name = app.name.clone();
        vibe_row.connect_selected_notify(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |r| {
                let v = VIBES.get(r.selected() as usize).copied().unwrap_or("Standard");
                page.set_app_style(&name, "", "", v, format!("Vibration · {v}"));
            }
        ));
        g2.add(&vibe_row);

        let icon_model = gtk::StringList::new(&ICONS);
        let icon_row = adw::ComboRow::builder()
            .title("Custom icon")
            .subtitle("Glyph shown on the watch")
            .model(&icon_model)
            .build();
        icon_row.set_selected(ICONS.iter().position(|v| *v == app.icon).unwrap_or(0) as u32);
        let name = app.name.clone();
        icon_row.connect_selected_notify(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |r| {
                let ic = ICONS.get(r.selected() as usize).copied().unwrap_or("Default");
                page.set_app_style(&name, "", ic, "", format!("Icon · {ic}"));
            }
        ));
        g2.add(&icon_row);

        let app_name_labels: Vec<&str> = APP_NAMES.iter().map(|(t, _)| *t).collect();
        let now = match self.imp().global_app_name.get() {
            Some(token) => format!(", now {}", APP_NAMES[app_name_index(token)].0),
            None => String::new(),
        };
        let app_name_row = adw::ComboRow::builder()
            .title("App name")
            .subtitle(format!("Default follows the Alerts page{now}."))
            .model(&gtk::StringList::new(&app_name_labels))
            .build();
        let name_idx = app_name_index(&app.app_name_placement);
        app_name_row.set_selected(name_idx as u32);
        preview.set_placement(self.app_name_placement(name_idx));
        let name = app.name.clone();
        app_name_row.connect_selected_notify(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            preview,
            move |r| {
                let (text, value) =
                    APP_NAMES.get(r.selected() as usize).copied().unwrap_or(APP_NAMES[0]);
                preview.set_placement(page.app_name_placement(r.selected() as usize));
                page.set_app_name(&name, text, value);
            }
        ));
        g2.add(&app_name_row);
        g2.add(preview.widget()); // not a row: goes under the list
        prefs.add(&g2);

        let header = adw::HeaderBar::new();
        let tv = adw::ToolbarView::new();
        tv.add_top_bar(&header);
        tv.set_content(Some(&prefs));
        let dialog = adw::Dialog::new();
        dialog.set_title(&esc(&app.name));
        dialog.set_content_width(420);
        dialog.set_content_height(560);
        dialog.set_child(Some(&tv));
        dialog.present(Some(self));
        (dialog, preview)
    }

    // --- filters --------------------------------------------------------------

    fn rebuild_filters(&self) {
        let imp = self.imp();
        for w in imp.filter_rows.borrow_mut().drain(..) {
            imp.filters_group.remove(&w);
        }
        let filters = imp.filters.borrow().clone();
        if filters.is_empty() {
            let empty = adw::ActionRow::builder()
                .title("No filters")
                .subtitle("Add a regex filter to allow or block matching notifications.")
                .build();
            imp.filters_group.add(&empty);
            imp.filter_rows.borrow_mut().push(empty.upcast());
            return;
        }
        for f in &filters {
            let block = f.action == "block";
            let row = adw::ActionRow::builder()
                .title(&esc(&f.pattern))
                .subtitle(if block { "Block matching" } else { "Always allow" })
                .build();
            row.add_css_class("mono");
            let icon = gtk::Image::from_icon_name("system-search-symbolic");
            icon.add_css_class(if block { "error" } else { "success" });
            row.add_prefix(&icon);
            let remove = gtk::Button::from_icon_name("user-trash-symbolic");
            remove.set_valign(gtk::Align::Center);
            remove.add_css_class("flat");
            remove.set_tooltip_text(Some("Remove filter"));
            let pattern = f.pattern.clone();
            remove.connect_clicked(glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_| page.remove_filter(&pattern)
            ));
            row.add_suffix(&remove);
            imp.filters_group.add(&row);
            imp.filter_rows.borrow_mut().push(row.upcast());
        }
    }

    fn remove_filter(&self, pattern: &str) {
        let client = self.client();
        let pattern = pattern.to_string();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let s = client.notif_remove_filter(&pattern).await;
                if !s.ok() {
                    let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                    page.toast(&format!("Remove failed: {m}"));
                }
                page.reload().await;
            }
        ));
    }

    /// Push one notification through the real send path — the same choke point desktop and extension
    /// notifications use, so per-app mute, the filters and the master switch all apply. That is the
    /// point: it answers "is anything on this screen stopping my notifications?" rather than bypassing
    /// them to look good.
    fn send_test(&self) {
        let client = self.client();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let body = format!(
                    "Sent from stoandl at {}",
                    glib::DateTime::now_local()
                        .ok()
                        .and_then(|d| d.format("%H:%M").ok())
                        .map(|s| s.to_string())
                        .unwrap_or_default()
                );
                let s = client.send_test_notification("Test notification", &body).await;
                if s.ok() {
                    page.toast("Test notification sent to the watch");
                } else if s.kind == "notready" {
                    page.toast("No watch connected");
                } else {
                    let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                    page.toast(&format!("Not sent: {m}"));
                }
                // Re-fetch is authoritative: a test send lazily tracks "stoandl" as a new app, so the
                // per-app list gains a row.
                page.reload().await;
            }
        ));
    }

    fn open_add_filter(&self) {
        let pattern = adw::EntryRow::builder().title("Regex pattern").build();
        pattern.add_css_class("mono");
        let action = adw::ComboRow::builder()
            .title("Action")
            .model(&gtk::StringList::new(&["Block matching", "Always allow"]))
            .build();
        let group = adw::PreferencesGroup::new();
        group.add(&pattern);
        group.add(&action);

        let dialog = adw::AlertDialog::new(
            Some("Add filter"),
            Some("Regex matched on the notification title and body."),
        );
        dialog.set_extra_child(Some(&group));
        dialog.add_response("cancel", "Cancel");
        dialog.add_response("add", "Add");
        dialog.set_response_appearance("add", adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some("add"));
        dialog.set_close_response("cancel");
        dialog.set_response_enabled("add", false);
        pattern.connect_changed(glib::clone!(
            #[weak]
            dialog,
            move |e| dialog.set_response_enabled("add", !e.text().trim().is_empty())
        ));
        dialog.connect_response(
            None,
            glib::clone!(
                #[weak(rename_to = page)]
                self,
                #[weak]
                pattern,
                #[weak]
                action,
                move |_, resp| {
                    if resp != "add" {
                        return;
                    }
                    let pat = pattern.text().trim().to_string();
                    if pat.is_empty() {
                        return;
                    }
                    let act = if action.selected() == 0 { "block" } else { "allow" };
                    let client = page.client();
                    let act = act.to_string();
                    glib::spawn_future_local(glib::clone!(
                        #[weak]
                        page,
                        #[strong]
                        client,
                        async move {
                            let s = client.notif_add_filter(&pat, &act).await;
                            if s.ok() {
                                page.toast("Filter added");
                            } else {
                                let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                                page.toast(&format!("Add filter failed: {m}"));
                            }
                            page.reload().await;
                        }
                    ));
                }
            ),
        );
        dialog.present(Some(self));
    }

    /// Headless smoke hook — the default view already renders everything; this adds
    /// the send-test path, the app-name choice with its preview and the per-app
    /// dialog, which only a click reaches.
    pub fn smoke_exercise(&self) {
        if std::env::var_os("STOANDL_SMOKE_MS").is_none() {
            return;
        }
        // Exercise the send-test path too — it is the only control here that goes through
        // SendTestNotification, so nothing else would cover it. Skipped when the daemon is down: the
        // button is insensitive then, so firing it would exercise a path a user cannot reach.
        if self.client().daemon_up() {
            self.send_test();
        }
        // The global app name: the preview for each placement (without the write), then the stored
        // value written back unchanged (a no-op, also against a real daemon).
        let global = self.imp().global_app_name.get().filter(|_| self.client().daemon_up());
        if let (Some(preview), Some(stored)) = (self.imp().preview.get(), global) {
            for &(_, token) in &APP_NAMES[1..] {
                preview.set_placement(token);
                dbg_preview(preview);
            }
            preview.set_placement(stored);
            let label = APP_NAMES[app_name_index(stored)].0;
            dbg_smoke(&format!("notif app name global = {label}"));
            self.set_global_app_name(label);
        }
        // The per-app dialog, for an app with an app-name override if there is one: its preselection
        // comes from NotifList's 7th column, and the same value goes back through NotifSetAppName
        // (a no-op change, also against a real daemon). Its preview shows that override, then —
        // without the write — "Default", which follows the global placement.
        let app = {
            let apps = self.imp().apps.borrow();
            apps.iter().find(|a| !a.app_name_placement.is_empty()).or(apps.first()).cloned()
        };
        if let Some(app) = app.filter(|_| self.client().daemon_up()) {
            let (dialog, preview) = self.open_app_dialog(&app);
            dbg_preview(&preview);
            let (label, value) = APP_NAMES[app_name_index(&app.app_name_placement)];
            dbg_smoke(&format!("notif app name: {} = {label}", app.name));
            self.set_app_name(&app.name, label, value);
            preview.set_placement(self.app_name_placement(0));
            dbg_preview(&preview);
            dialog.close();
        }
        dbg_smoke("exercised notifications page");
    }
}
