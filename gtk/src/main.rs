mod application;
mod config;
mod dbus;
mod pages;
mod widgets;
mod window;

use adw::prelude::*;
use gtk::{gio, glib};

use crate::application::StoandlApplication;

fn main() -> glib::ExitCode {
    // The compiled Blueprint UI + CSS bundle produced by build.rs.
    gio::resources_register_include!("stoandl.gresource")
        .expect("failed to register GResource bundle");

    glib::set_application_name("stoandl (GTK)");
    // Note: the default icon name is set in StoandlApplication::startup — any
    // gtk::* call here would run before app.run() initialises GTK and panic.

    let app = StoandlApplication::new();
    app.run()
}
