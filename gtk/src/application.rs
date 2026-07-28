use adw::prelude::*;
use adw::subclass::prelude::*;
use gtk::{gio, glib};

use crate::config::{APP_ID, RESOURCE_PREFIX};
use crate::window::StoandlWindow;

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct StoandlApplication;

    #[glib::object_subclass]
    impl ObjectSubclass for StoandlApplication {
        const NAME: &'static str = "StoandlApplication";
        type Type = super::StoandlApplication;
        type ParentType = adw::Application;
    }

    impl ObjectImpl for StoandlApplication {
        fn constructed(&self) {
            self.parent_constructed();
            let app = self.obj();
            app.set_accels_for_action("app.quit", &["<primary>q"]);

            let quit = gio::ActionEntry::builder("quit")
                .activate(|app: &super::StoandlApplication, _, _| app.quit())
                .build();
            app.add_action_entries([quit]);
        }
    }

    impl ApplicationImpl for StoandlApplication {
        fn startup(&self) {
            self.parent_startup();
            // Safe here: GApplication startup runs after GTK is initialised.
            gtk::Window::set_default_icon_name(APP_ID);
        }

        fn activate(&self) {
            let app = self.obj();
            let window = app
                .active_window()
                .unwrap_or_else(|| StoandlWindow::new(&*app).upcast());
            window.present();
        }
    }

    impl GtkApplicationImpl for StoandlApplication {}
    impl AdwApplicationImpl for StoandlApplication {}
}

glib::wrapper! {
    pub struct StoandlApplication(ObjectSubclass<imp::StoandlApplication>)
        @extends gio::Application, gtk::Application, adw::Application,
        @implements gio::ActionGroup, gio::ActionMap;
}

impl StoandlApplication {
    pub fn new() -> Self {
        glib::Object::builder()
            .property("application-id", APP_ID)
            // Pin the resource base path to RESOURCE_PREFIX rather than letting
            // GtkApplication derive it from the application-id. The GResource bundle
            // (and thus the auto icon-theme search dir `<base>/icons`, where the
            // heart lives) is laid out under /de/yoxcu/stoandl/gui; the `.gtk` app-id
            // suffix must not drag that to /de/yoxcu/stoandl/gui/gtk or named icons
            // stop resolving when run uninstalled.
            .property("resource-base-path", RESOURCE_PREFIX)
            .property("flags", gio::ApplicationFlags::empty())
            .build()
    }
}

impl Default for StoandlApplication {
    fn default() -> Self {
        Self::new()
    }
}
