use adw::prelude::*;
use adw::subclass::prelude::*;
use gtk::{gio, glib, CompositeTemplate};

use crate::dbus::StoandlClient;

mod imp {
    use super::*;
    use std::cell::OnceCell;

    #[derive(CompositeTemplate, Default)]
    #[template(resource = "/de/yoxcu/stoandl/gui/ui/window.ui")]
    pub struct StoandlWindow {
        #[template_child]
        pub root_stack: TemplateChild<gtk::Stack>,
        #[template_child]
        pub toast_overlay: TemplateChild<adw::ToastOverlay>,
        #[template_child]
        pub view_stack: TemplateChild<adw::ViewStack>,
        #[template_child]
        pub start_daemon_button: TemplateChild<gtk::Button>,

        pub client: OnceCell<StoandlClient>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for StoandlWindow {
        const NAME: &'static str = "StoandlWindow";
        type Type = super::StoandlWindow;
        type ParentType = adw::ApplicationWindow;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(obj: &glib::subclass::InitializingObject<Self>) {
            obj.init_template();
        }
    }

    impl ObjectImpl for StoandlWindow {
        fn constructed(&self) {
            self.parent_constructed();
            self.obj().setup();
        }
    }

    impl WidgetImpl for StoandlWindow {}
    impl WindowImpl for StoandlWindow {}
    impl ApplicationWindowImpl for StoandlWindow {}
    impl AdwApplicationWindowImpl for StoandlWindow {}
}

glib::wrapper! {
    pub struct StoandlWindow(ObjectSubclass<imp::StoandlWindow>)
        @extends adw::ApplicationWindow, gtk::ApplicationWindow, gtk::Window, gtk::Widget,
        @implements gio::ActionGroup, gio::ActionMap, gtk::Root, gtk::Native, gtk::ShortcutManager;
}

impl StoandlWindow {
    pub fn new(app: &impl IsA<gtk::Application>) -> Self {
        glib::Object::builder().property("application", app).build()
    }

    fn setup(&self) {
        let imp = self.imp();
        let client = StoandlClient::new();

        // Reflect daemon liveness onto the root stack: the whole nav disappears
        // when the daemon is down (a per-page placeholder is unnecessary here —
        // GTK can centralise it, since nothing works without the daemon).
        let update_root = {
            let win = self.downgrade();
            move |c: &StoandlClient| {
                if let Some(win) = win.upgrade() {
                    win.imp()
                        .root_stack
                        .set_visible_child_name(if c.daemon_up() { "main" } else { "daemon" });
                }
            }
        };
        client.connect_notify_local(
            Some("daemon-up"),
            glib::clone!(
                #[strong]
                update_root,
                move |c, _| update_root(c)
            ),
        );

        // "Start daemon" — the daemon is NOT D-Bus-activated.
        imp.start_daemon_button.connect_clicked(glib::clone!(
            #[weak(rename_to = win)]
            self,
            #[weak]
            client,
            move |_| {
                client.start_daemon();
                win.toast("Starting stoandl…");
            }
        ));

        update_root(&client);
        // Connect synchronously (sets the bus connection + signal subscriptions)
        // before building pages, so their initial refresh/poll has a connection.
        client.start();

        // Build the 5 nav destinations and wire them to the shared client.
        let view_stack = imp.view_stack.get();
        crate::pages::install(&view_stack, &client);

        imp.client.set(client).ok();

        self.maybe_start_smoke();
    }

    /// Headless verification harness (sandbox only, gated on `STOANDL_SMOKE_MS`).
    /// Steps through every `view_stack` destination one per tick, then quits the
    /// app — the GTK analogue of the Qt offscreen tab-cycle test. Lets
    /// `run-with-mock-gtk.sh --headless` prove Blueprint→GResource→GDBus→mock→
    /// render end-to-end and self-terminate, and (as pages land) surfaces any
    /// per-page GTK/Adwaita CRITICAL/WARNING on stderr.
    fn maybe_start_smoke(&self) {
        let Ok(val) = std::env::var("STOANDL_SMOKE_MS") else {
            return;
        };
        let step = std::time::Duration::from_millis(val.parse().unwrap_or(400));
        let win = self.downgrade();
        let mut idx: u32 = 0;
        glib::timeout_add_local(step, move || {
            let Some(win) = win.upgrade() else {
                return glib::ControlFlow::Break;
            };
            let stack = &win.imp().view_stack;
            let pages = stack.pages();
            if idx >= pages.n_items() {
                eprintln!("stoandl-smoke: cycled all {} pages, quitting", pages.n_items());
                if let Some(app) = win.application() {
                    app.quit();
                }
                return glib::ControlFlow::Break;
            }
            if let Some(page) = pages.item(idx).and_downcast::<adw::ViewStackPage>() {
                let child = page.child();
                stack.set_visible_child(&child);
                eprintln!(
                    "stoandl-smoke: page {} -> {}",
                    idx,
                    page.name().unwrap_or_default()
                );
                // Deep-exercise each page's non-default states.
                if let Some(watch) = child.downcast_ref::<crate::pages::StoandlWatchPage>() {
                    watch.smoke_exercise();
                }
                if let Some(health) = child.downcast_ref::<crate::pages::StoandlHealthPage>() {
                    health.smoke_exercise();
                }
                if let Some(apps) = child.downcast_ref::<crate::pages::StoandlAppsPage>() {
                    apps.smoke_exercise();
                }
                if let Some(n) = child.downcast_ref::<crate::pages::StoandlNotificationsPage>() {
                    n.smoke_exercise();
                }
                if let Some(s) = child.downcast_ref::<crate::pages::StoandlSettingsPage>() {
                    s.smoke_exercise();
                }
            }
            idx += 1;
            glib::ControlFlow::Continue
        });
    }

    /// App-wide transient feedback (the AdwToast analogue of showPassiveNotification).
    /// Markup is disabled: toasts carry raw daemon text (URLs, error messages) that
    /// may contain `&`/`<`, which would otherwise mis-render as Pango markup.
    pub fn toast(&self, msg: &str) {
        let toast = adw::Toast::new(msg);
        toast.set_use_markup(false);
        self.imp().toast_overlay.add_toast(toast);
    }

    pub fn client(&self) -> StoandlClient {
        self.imp().client.get().expect("client initialised").clone()
    }
}
