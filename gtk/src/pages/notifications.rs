//! The Notifications tab (`StoandlNotificationsPage`) — port of
//! `qml/NotificationsPage.qml`. Master forward toggle (via sync-status) + a
//! temporary mute, a per-app list (each row opens a deeper dialog for on/off,
//! temp-mute, vibration + icon), and regex allow/block filters. No change
//! signals — every mutation re-fetches (reload).

use std::cell::{Cell, OnceCell, RefCell};

use adw::prelude::*;
use adw::subclass::prelude::*;
use gtk::{glib, CompositeTemplate};

use super::esc;
use crate::dbus::{NotifApp, NotifFilter, StoandlClient};
use crate::window::StoandlWindow;

const VIBES: [&str; 5] = ["Standard", "Double", "Long", "Subtle", "Heartbeat"];
const ICONS: [&str; 4] = ["Default", "Bell", "Calendar", "Chat"];

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

        self.imp().add_filter_button.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.open_add_filter()
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

        // A newer mutation+reload superseded us while awaiting — don't rebuild the
        // per-app rows from this stale snapshot (it could revert a just-set switch).
        if self.imp().reload_gen.get() != generation {
            return;
        }
        *self.imp().apps.borrow_mut() = apps;
        *self.imp().filters.borrow_mut() = filters;
        self.update_ui(forward);
    }

    fn all_muted(&self) -> bool {
        let apps = self.imp().apps.borrow();
        !apps.is_empty() && apps.iter().all(|a| a.muted)
    }

    fn update_ui(&self, forward: bool) {
        let imp = self.imp();
        // Guarded set so it doesn't re-trigger the toggle handler.
        imp.updating.set(true);
        imp.forward_switch.set_active(forward);
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
            move |_| page.open_app_dialog(&app)
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

    fn open_app_dialog(&self, app: &NotifApp) {
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

        // Vibration + icon.
        let g2 = adw::PreferencesGroup::new();
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

    /// Headless smoke hook — the default view already renders everything, so this
    /// just marks the page was reached.
    pub fn smoke_exercise(&self) {
        if std::env::var_os("STOANDL_SMOKE_MS").is_none() {
            return;
        }
        dbg_smoke("exercised notifications page");
    }
}
