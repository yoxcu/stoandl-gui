//! The Apps tab (`StoandlAppsPage`) — port of `qml/AppsPage.qml`. Three segments
//! (Faces / Apps / Extensions) via a linked toggle bar; app rows lazily load
//! their menu icon (GetAppIcon); extensions toggle enable + have a config
//! backend (url → open, or a JSON schema → a native form dialog).

use std::cell::{OnceCell, RefCell};

use adw::prelude::*;
use adw::subclass::prelude::*;
use gtk::{gio, glib, CompositeTemplate};

use super::esc;
use crate::dbus::{AppRow, ExtField, ExtRow, StoandlClient};
use crate::window::StoandlWindow;

fn dbg_smoke(msg: &str) {
    if std::env::var_os("STOANDL_SMOKE_MS").is_some() {
        eprintln!("stoandl-smoke: {msg}");
    }
}

/// A live control in the extension config form, tagged by its schema type.
enum Ctl {
    Bool(adw::SwitchRow),
    Entry(adw::EntryRow),
    Password(adw::PasswordEntryRow),
    Int(adw::SpinRow),
    Enum(adw::ComboRow, Vec<String>),
}

impl Ctl {
    fn value(&self) -> serde_json::Value {
        match self {
            Ctl::Bool(w) => serde_json::Value::Bool(w.is_active()),
            Ctl::Entry(w) => serde_json::Value::String(w.text().to_string()),
            Ctl::Password(w) => serde_json::Value::String(w.text().to_string()),
            Ctl::Int(w) => serde_json::Value::from(w.value().round() as i64),
            Ctl::Enum(w, opts) => {
                let idx = w.selected() as usize;
                serde_json::Value::String(opts.get(idx).cloned().unwrap_or_default())
            }
        }
    }
}

mod imp {
    use super::*;

    #[derive(CompositeTemplate, Default)]
    #[template(resource = "/de/yoxcu/stoandl/gui/ui/apps.ui")]
    pub struct StoandlAppsPage {
        #[template_child]
        pub install_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub refresh_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub faces_btn: TemplateChild<gtk::ToggleButton>,
        #[template_child]
        pub apps_btn: TemplateChild<gtk::ToggleButton>,
        #[template_child]
        pub ext_btn: TemplateChild<gtk::ToggleButton>,
        #[template_child]
        pub faces_label: TemplateChild<gtk::Label>,
        #[template_child]
        pub apps_label: TemplateChild<gtk::Label>,
        #[template_child]
        pub ext_label: TemplateChild<gtk::Label>,
        #[template_child]
        pub segment_stack: TemplateChild<gtk::Stack>,
        #[template_child]
        pub faces_stack: TemplateChild<gtk::Stack>,
        #[template_child]
        pub faces_status: TemplateChild<adw::StatusPage>,
        #[template_child]
        pub faces_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub apps_stack: TemplateChild<gtk::Stack>,
        #[template_child]
        pub apps_status: TemplateChild<adw::StatusPage>,
        #[template_child]
        pub apps_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub ext_stack: TemplateChild<gtk::Stack>,
        #[template_child]
        pub ext_status: TemplateChild<adw::StatusPage>,
        #[template_child]
        pub ext_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub view_switcher: TemplateChild<adw::ViewSwitcher>,
        #[template_child]
        pub switcher_bar: TemplateChild<adw::ViewSwitcherBar>,

        pub client: OnceCell<StoandlClient>,
        pub segment: RefCell<String>,
        pub faces_rows: RefCell<Vec<gtk::Widget>>,
        pub apps_rows: RefCell<Vec<gtk::Widget>>,
        pub ext_rows: RefCell<Vec<gtk::Widget>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for StoandlAppsPage {
        const NAME: &'static str = "StoandlAppsPage";
        type Type = super::StoandlAppsPage;
        type ParentType = adw::BreakpointBin;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }
        fn instance_init(obj: &glib::subclass::InitializingObject<Self>) {
            obj.init_template();
        }
    }

    impl ObjectImpl for StoandlAppsPage {
        fn constructed(&self) {
            self.parent_constructed();
            self.segment.replace("faces".to_string());
        }
    }
    impl WidgetImpl for StoandlAppsPage {}
    impl BreakpointBinImpl for StoandlAppsPage {}
}

glib::wrapper! {
    pub struct StoandlAppsPage(ObjectSubclass<imp::StoandlAppsPage>)
        @extends adw::BreakpointBin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl Default for StoandlAppsPage {
    fn default() -> Self {
        Self::new()
    }
}

impl StoandlAppsPage {
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

    pub fn bind_client(&self, client: &StoandlClient) {
        self.imp().client.set(client.clone()).ok();

        self.imp().install_button.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.install()
        ));
        self.imp().refresh_button.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| {
                page.reload();
                page.toast("Refreshed");
            }
        ));
        for (btn, seg) in [
            (self.imp().faces_btn.get(), "faces"),
            (self.imp().apps_btn.get(), "apps"),
            (self.imp().ext_btn.get(), "ext"),
        ] {
            btn.connect_toggled(glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |b| {
                    if b.is_active() {
                        page.set_segment(seg);
                    }
                }
            ));
        }

        // Restore the empty-state call-to-action (the QML PlaceholderMessage's
        // helpfulAction): a prominent Install button on each empty segment.
        for (status, label) in [
            (self.imp().faces_status.get(), "Install .pbw"),
            (self.imp().apps_status.get(), "Install .pbw"),
            (self.imp().ext_status.get(), "Install extension"),
        ] {
            let btn = gtk::Button::with_label(label);
            btn.set_halign(gtk::Align::Center);
            btn.add_css_class("pill");
            btn.add_css_class("suggested-action");
            btn.connect_clicked(glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_| page.install()
            ));
            status.set_child(Some(&btn));
        }

        client.connect_apps_changed(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.rebuild_apps()
        ));
        client.connect_extensions_changed(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.rebuild_ext()
        ));
        client.connect_notify_local(
            Some("daemon-up"),
            glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |c, _| {
                    if c.daemon_up() {
                        page.reload();
                    }
                }
            ),
        );

        self.reload();
    }

    fn set_segment(&self, seg: &str) {
        self.imp().segment.replace(seg.to_string());
        self.imp().segment_stack.set_visible_child_name(seg);
        self.imp()
            .install_button
            .set_tooltip_text(Some(if seg == "ext" { "Install extension" } else { "Install .pbw" }));
    }

    fn reload(&self) {
        let client = self.client();
        glib::spawn_future_local(glib::clone!(
            #[strong]
            client,
            async move {
                client.refresh_apps().await;
                client.refresh_extensions().await;
            }
        ));
    }

    // --- rebuild lists --------------------------------------------------------

    fn clear(group: &adw::PreferencesGroup, rows: &RefCell<Vec<gtk::Widget>>) {
        for w in rows.borrow_mut().drain(..) {
            group.remove(&w);
        }
    }

    fn rebuild_apps(&self) {
        let imp = self.imp();
        let apps = self.client().apps();
        let faces: Vec<AppRow> = apps.iter().filter(|a| a.is_face).cloned().collect();
        let others: Vec<AppRow> = apps.iter().filter(|a| !a.is_face).cloned().collect();

        Self::clear(&imp.faces_group, &imp.faces_rows);
        for a in &faces {
            let row = self.app_row(a);
            imp.faces_group.add(&row);
            imp.faces_rows.borrow_mut().push(row.upcast());
        }
        Self::clear(&imp.apps_group, &imp.apps_rows);
        for a in &others {
            let row = self.app_row(a);
            imp.apps_group.add(&row);
            imp.apps_rows.borrow_mut().push(row.upcast());
        }

        imp.faces_stack
            .set_visible_child_name(if faces.is_empty() { "empty" } else { "list" });
        imp.apps_stack
            .set_visible_child_name(if others.is_empty() { "empty" } else { "list" });
        imp.faces_label.set_label(&format!("Faces · {}", faces.len()));
        imp.apps_label.set_label(&format!("Apps · {}", others.len()));

        dbg_smoke(&format!("apps rebuild: {} faces, {} apps", faces.len(), others.len()));
    }

    fn rebuild_ext(&self) {
        let imp = self.imp();
        let exts = self.client().extensions();
        Self::clear(&imp.ext_group, &imp.ext_rows);
        for e in &exts {
            let row = self.ext_row(e);
            imp.ext_group.add(&row);
            imp.ext_rows.borrow_mut().push(row.upcast());
        }
        imp.ext_stack
            .set_visible_child_name(if exts.is_empty() { "empty" } else { "list" });
        imp.ext_label.set_label(&format!("Extensions · {}", exts.len()));
        dbg_smoke(&format!("ext rebuild: {} extensions", exts.len()));
    }

    // --- app row --------------------------------------------------------------

    fn app_row(&self, app: &AppRow) -> adw::ActionRow {
        let who = if app.developer.is_empty() { &app.uuid } else { &app.developer };
        let subtitle = if app.version.is_empty() {
            who.clone()
        } else {
            format!("{who} · v{}", app.version)
        };
        let row = adw::ActionRow::builder()
            .title(&esc(&app.title))
            .subtitle(&esc(&subtitle))
            .activatable(true)
            .build();

        // Fallback glyph now; lazily replace with the daemon's menu icon.
        let fallback = if app.active {
            "starred-symbolic"
        } else if app.is_face {
            "preferences-desktop-theme-symbolic"
        } else {
            "application-x-executable-symbolic"
        };
        let icon = gtk::Image::from_icon_name(fallback);
        icon.set_pixel_size(32);
        if app.active {
            icon.add_css_class("accent");
        }
        row.add_prefix(&icon);
        let uuid = app.uuid.clone();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[weak]
            icon,
            async move {
                if let Some(path) = page.client().app_icon(&uuid).await {
                    icon.set_from_file(Some(&path));
                    icon.set_pixel_size(32);
                }
            }
        ));

        if app.active {
            let pill = gtk::Label::new(Some("active"));
            pill.set_valign(gtk::Align::Center);
            pill.add_css_class("status-chip");
            pill.add_css_class("success");
            row.add_suffix(&pill);
        }
        if app.config {
            let cfg = gtk::Button::from_icon_name("emblem-system-symbolic");
            cfg.set_valign(gtk::Align::Center);
            cfg.add_css_class("flat");
            cfg.set_tooltip_text(Some("Settings"));
            let uuid = app.uuid.clone();
            cfg.connect_clicked(glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_| page.open_app_config(&uuid)
            ));
            row.add_suffix(&cfg);
        }
        if !app.system {
            let del = gtk::Button::from_icon_name("user-trash-symbolic");
            del.set_valign(gtk::Align::Center);
            del.add_css_class("flat");
            del.set_tooltip_text(Some("Delete from locker"));
            let app = app.clone();
            del.connect_clicked(glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_| page.confirm_remove(&app)
            ));
            row.add_suffix(&del);
        }

        let app = app.clone();
        row.connect_activated(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.launch(&app)
        ));
        row
    }

    fn launch(&self, app: &AppRow) {
        let client = self.client();
        let (uuid, title) = (app.uuid.clone(), app.title.clone());
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let s = client.launch_app(&uuid).await;
                if s.ok() {
                    page.toast(&format!("Launched {title}"));
                } else {
                    let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                    page.toast(&format!("Launch failed: {m}"));
                }
                client.refresh_apps().await; // launching a face changes the active flag
            }
        ));
    }

    fn open_app_config(&self, uuid: &str) {
        let client = self.client();
        let uuid = uuid.to_string();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let (kind, url, msg) = client.open_config(&uuid).await;
                if kind == "ok" && !url.is_empty() {
                    page.launch_url(&url);
                    page.toast("Opening config in your browser…");
                } else if kind == "none" {
                    page.toast("No config available — is the app running on the watch?");
                } else {
                    let m = if msg.is_empty() { kind } else { msg };
                    page.toast(&format!("Config unavailable: {m}"));
                }
            }
        ));
    }

    fn confirm_remove(&self, app: &AppRow) {
        let label = if app.title.is_empty() { app.uuid.clone() } else { app.title.clone() };
        let body =
            format!("Remove “{label}” from the locker? You can install it again later.");
        let dialog = adw::AlertDialog::new(Some("Delete from locker"), Some(&body));
        dialog.add_response("cancel", "Cancel");
        dialog.add_response("delete", "Delete");
        dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let uuid = app.uuid.clone();
        dialog.connect_response(
            None,
            glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_, resp| {
                    if resp != "delete" {
                        return;
                    }
                    let client = page.client();
                    let uuid = uuid.clone();
                    glib::spawn_future_local(glib::clone!(
                        #[weak]
                        page,
                        #[strong]
                        client,
                        async move {
                            let s = client.remove_app(&uuid).await;
                            if !s.ok() {
                                let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                                page.toast(&format!("Remove failed: {m}"));
                            }
                            client.refresh_apps().await;
                        }
                    ));
                }
            ),
        );
        dialog.present(Some(self));
    }

    // --- extension row --------------------------------------------------------

    fn ext_row(&self, ext: &ExtRow) -> adw::SwitchRow {
        let mut head: Vec<String> = Vec::new();
        if !ext.author.is_empty() {
            head.push(ext.author.clone());
        }
        if !ext.version.is_empty() {
            head.push(format!("v{}", ext.version));
        }
        let head = head.join(" · ");
        let subtitle = if ext.description.is_empty() {
            head
        } else if head.is_empty() {
            ext.description.clone()
        } else {
            format!("{head} — {}", ext.description)
        };

        let row = adw::SwitchRow::builder()
            .title(&esc(&ext.name))
            .subtitle(&esc(&subtitle))
            .build();
        row.set_active(ext.enabled); // set BEFORE connecting so no spurious toggle

        // Runtime chip (only for quarantined/exited — the states the poll misses).
        match ext.runtime_state.as_str() {
            "quarantined" | "exited" => {
                let quarantined = ext.runtime_state == "quarantined";
                let pill = gtk::Label::new(Some(if quarantined {
                    "Quarantined"
                } else {
                    "Crashed (restarting)"
                }));
                pill.set_valign(gtk::Align::Center);
                pill.add_css_class("status-chip");
                pill.add_css_class(if quarantined { "error" } else { "warning" });
                row.add_suffix(&pill);
            }
            _ => {}
        }

        if ext.has_config {
            let cfg = gtk::Button::from_icon_name("emblem-system-symbolic");
            cfg.set_valign(gtk::Align::Center);
            cfg.add_css_class("flat");
            cfg.set_tooltip_text(Some("Settings"));
            let ext = ext.clone();
            cfg.connect_clicked(glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_| page.configure_ext(&ext)
            ));
            row.add_suffix(&cfg);
        }

        let uninstall = gtk::Button::from_icon_name("user-trash-symbolic");
        uninstall.set_valign(gtk::Align::Center);
        uninstall.add_css_class("flat");
        uninstall.set_tooltip_text(Some("Uninstall"));
        let name = ext.name.clone();
        uninstall.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.confirm_uninstall(&name)
        ));
        row.add_suffix(&uninstall);

        let name = ext.name.clone();
        row.connect_active_notify(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |r| page.ext_toggle(&name, r.is_active())
        ));
        row
    }

    fn ext_toggle(&self, name: &str, want_enabled: bool) {
        let client = self.client();
        let name = name.to_string();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let s = if want_enabled {
                    client.ext_enable(&name).await
                } else {
                    client.ext_disable(&name).await
                };
                if !s.ok() {
                    let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                    page.toast(&format!(
                        "{} failed: {m}",
                        if want_enabled { "Enable" } else { "Disable" }
                    ));
                }
                client.refresh_extensions().await;
            }
        ));
    }

    fn configure_ext(&self, ext: &ExtRow) {
        match ext.config.as_str() {
            "url" => {
                let client = self.client();
                let name = ext.name.clone();
                glib::spawn_future_local(glib::clone!(
                    #[weak(rename_to = page)]
                    self,
                    #[strong]
                    client,
                    async move {
                        let (kind, url, msg) = client.ext_open_config(&name).await;
                        if kind == "ok" && !url.is_empty() {
                            page.launch_url(&url);
                            page.toast(&format!("Opening {name} settings…"));
                        } else {
                            let m = if msg.is_empty() { kind } else { msg };
                            page.toast(&format!("Settings unavailable: {m}"));
                        }
                    }
                ));
            }
            "schema" => self.open_ext_config_form(&ext.name),
            _ => self.toast(&format!("No settings for {}", ext.name)),
        }
    }

    fn confirm_uninstall(&self, name: &str) {
        let dialog = adw::AlertDialog::new(
            Some("Uninstall extension"),
            Some(&format!("Stops {name} and removes its files.")),
        );
        let keep = adw::SwitchRow::builder()
            .title("Keep configuration")
            .subtitle("So you can reinstall later")
            .active(true)
            .build();
        let group = adw::PreferencesGroup::new();
        group.add(&keep);
        dialog.set_extra_child(Some(&group));
        dialog.add_response("cancel", "Cancel");
        dialog.add_response("uninstall", "Uninstall");
        dialog.set_response_appearance("uninstall", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let name = name.to_string();
        dialog.connect_response(
            None,
            glib::clone!(
                #[weak(rename_to = page)]
                self,
                #[weak]
                keep,
                move |_, resp| {
                    if resp != "uninstall" {
                        return;
                    }
                    let client = page.client();
                    let name = name.clone();
                    let keep_config = keep.is_active();
                    glib::spawn_future_local(glib::clone!(
                        #[weak]
                        page,
                        #[strong]
                        client,
                        async move {
                            let s = client.ext_uninstall(&name, keep_config).await;
                            if s.ok() {
                                page.toast(&format!("Uninstalled {name}"));
                            } else {
                                let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                                page.toast(&format!("Uninstall failed: {m}"));
                            }
                            client.refresh_extensions().await;
                        }
                    ));
                }
            ),
        );
        dialog.present(Some(self));
    }

    // --- extension schema config form ----------------------------------------

    fn open_ext_config_form(&self, name: &str) {
        let client = self.client();
        let name = name.to_string();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let fields = client.ext_config_schema(&name).await;
                let values = client.ext_get_config(&name).await;
                page.build_ext_config_dialog(&name, &fields, values);
            }
        ));
    }

    fn build_ext_config_dialog(
        &self,
        name: &str,
        fields: &[ExtField],
        values: serde_json::Map<String, serde_json::Value>,
    ) {
        let group = adw::PreferencesGroup::new();
        let mut controls: Vec<(String, Ctl)> = Vec::new();

        for f in fields {
            let cur = values.get(&f.key);
            match f.field_type.as_str() {
                "bool" => {
                    let on = cur
                        .map(|v| v.as_bool().unwrap_or_else(|| v.as_str() == Some("true")))
                        .unwrap_or(false);
                    let row = adw::SwitchRow::builder().title(&esc(&f.label)).active(on).build();
                    group.add(&row);
                    controls.push((f.key.clone(), Ctl::Bool(row)));
                }
                "int" => {
                    // Accept an int, a JSON float (round), or a numeric string —
                    // an off-contract float value shouldn't silently reset to 0.
                    let v = cur
                        .and_then(|v| {
                            v.as_i64()
                                .or_else(|| v.as_f64().map(|f| f.round() as i64))
                                .or_else(|| {
                                    v.as_str().and_then(|s| {
                                        s.trim().parse::<i64>().ok().or_else(|| {
                                            s.trim().parse::<f64>().ok().map(|f| f.round() as i64)
                                        })
                                    })
                                })
                        })
                        .unwrap_or(0);
                    let adj = gtk::Adjustment::new(v as f64, -1_000_000.0, 1_000_000.0, 1.0, 10.0, 0.0);
                    let row = adw::SpinRow::new(Some(&adj), 1.0, 0);
                    row.set_title(&esc(&f.label));
                    group.add(&row);
                    controls.push((f.key.clone(), Ctl::Int(row)));
                }
                "enum" => {
                    let model = gtk::StringList::new(
                        &f.options.iter().map(String::as_str).collect::<Vec<_>>(),
                    );
                    let row = adw::ComboRow::builder().title(&esc(&f.label)).model(&model).build();
                    let sel = cur
                        .and_then(|v| v.as_str())
                        .and_then(|s| f.options.iter().position(|o| o == s))
                        .unwrap_or(0);
                    row.set_selected(sel as u32);
                    group.add(&row);
                    controls.push((f.key.clone(), Ctl::Enum(row, f.options.clone())));
                }
                _ => {
                    // string (password echo when secret).
                    let text = cur
                        .map(|v| v.as_str().map(String::from).unwrap_or_else(|| v.to_string()))
                        .unwrap_or_default();
                    if f.secret {
                        let row = adw::PasswordEntryRow::builder().title(&esc(&f.label)).build();
                        row.set_text(&text);
                        group.add(&row);
                        controls.push((f.key.clone(), Ctl::Password(row)));
                    } else {
                        let row = adw::EntryRow::builder().title(&esc(&f.label)).build();
                        row.set_text(&text);
                        group.add(&row);
                        controls.push((f.key.clone(), Ctl::Entry(row)));
                    }
                }
            }
        }

        let prefs = adw::PreferencesPage::new();
        prefs.add(&group);

        let cancel = gtk::Button::with_label("Cancel");
        let save = gtk::Button::with_label("Save");
        save.add_css_class("suggested-action");
        let header = adw::HeaderBar::builder()
            .show_start_title_buttons(false)
            .show_end_title_buttons(false)
            .build();
        header.pack_start(&cancel);
        header.pack_end(&save);
        let tv = adw::ToolbarView::new();
        tv.add_top_bar(&header);
        tv.set_content(Some(&prefs));

        let dialog = adw::Dialog::new();
        dialog.set_title(&format!("{name} settings"));
        dialog.set_content_width(420);
        dialog.set_content_height(520);
        dialog.set_child(Some(&tv));

        cancel.connect_clicked(glib::clone!(
            #[weak]
            dialog,
            move |_| {
                dialog.close();
            }
        ));

        let name = name.to_string();
        let controls = std::rc::Rc::new(controls);
        save.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[weak]
            dialog,
            #[strong]
            controls,
            #[strong]
            name,
            move |_| {
                let mut map = serde_json::Map::new();
                for (key, ctl) in controls.iter() {
                    map.insert(key.clone(), ctl.value());
                }
                let client = page.client();
                let name = name.clone();
                glib::spawn_future_local(glib::clone!(
                    #[weak]
                    page,
                    #[strong]
                    client,
                    async move {
                        let s = client.ext_set_config(&name, map).await;
                        if s.ok() {
                            page.toast(&format!("Saved {name} settings"));
                        } else {
                            let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                            page.toast(&format!("Save failed: {m}"));
                        }
                        client.refresh_extensions().await;
                    }
                ));
                dialog.close();
            }
        ));

        dialog.present(Some(self));
    }

    // --- install (segment-aware file picker) ---------------------------------

    fn install(&self) {
        let is_ext = self.imp().segment.borrow().as_str() == "ext";
        let filter = gtk::FileFilter::new();
        if is_ext {
            filter.set_name(Some("Extension archives"));
            for s in ["tar.gz", "tgz", "tar", "zip"] {
                filter.add_suffix(s);
            }
        } else {
            filter.set_name(Some("Pebble apps (*.pbw)"));
            filter.add_suffix("pbw");
        }
        let filters = gio::ListStore::new::<gtk::FileFilter>();
        filters.append(&filter);
        let dialog = gtk::FileDialog::builder()
            .title(if is_ext { "Install extension" } else { "Install watchapp / watchface (.pbw)" })
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
                            page.do_install(&path.to_string_lossy(), is_ext);
                        }
                    }
                }
            ),
        );
    }

    fn do_install(&self, path: &str, is_ext: bool) {
        let client = self.client();
        let path = path.to_string();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                if is_ext {
                    let s = client.ext_install(&path).await;
                    if s.ok() {
                        page.toast("Extension installed");
                    } else {
                        let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                        page.toast(&format!("Install failed: {m}"));
                    }
                    client.refresh_extensions().await;
                } else {
                    let s = client.sideload_app(&path).await;
                    if s.ok() {
                        page.toast("Installed");
                    } else {
                        let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                        page.toast(&format!("Install failed: {m}"));
                    }
                    client.refresh_apps().await;
                }
            }
        ));
    }

    fn launch_url(&self, url: &str) {
        let launcher = gtk::UriLauncher::new(url);
        let parent = self.root().and_downcast::<gtk::Window>();
        launcher.launch(parent.as_ref(), gio::Cancellable::NONE, |_| {});
    }

    /// Headless smoke hook: cycle to Apps + Extensions segments so both lists render.
    pub fn smoke_exercise(&self) {
        if std::env::var_os("STOANDL_SMOKE_MS").is_none() {
            return;
        }
        self.set_segment("apps");
        self.set_segment("ext");
        dbg_smoke("exercised apps/ext segments");
    }
}
