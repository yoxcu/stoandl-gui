//! The 5 nav destinations. Each is added to the shell `Adw.ViewStack` in
//! `install()` (Watch first → tab 0). Real pages are composite-template widgets;
//! not-yet-ported tabs get an `Adw.StatusPage` placeholder.

mod apps;
mod health;
mod notifications;
mod settings;
mod watch;

pub use apps::StoandlAppsPage;
pub use health::StoandlHealthPage;
pub use notifications::StoandlNotificationsPage;
pub use settings::StoandlSettingsPage;
pub use watch::StoandlWatchPage;

use crate::dbus::StoandlClient;
use gtk::glib;

/// Escape a data-derived string for use as an Adw row title/subtitle — those
/// parse Pango markup, so a bare `&`/`<` from an app or extension name errors.
pub(crate) fn esc(s: &str) -> String {
    glib::markup_escape_text(s).to_string()
}

/// Build every destination and add it to the view stack, wiring each to the
/// shared client. Watch is added first so it is the launch view (tab 0).
pub fn install(view_stack: &adw::ViewStack, client: &StoandlClient) {
    let watch = StoandlWatchPage::new();
    watch.bind_client(client);
    view_stack.add_titled_with_icon(
        &watch,
        Some("watch"),
        "Watch",
        "preferences-system-time-symbolic",
    );
    watch.bind_switcher(view_stack);

    let health = StoandlHealthPage::new();
    health.bind_client(client);
    view_stack.add_titled_with_icon(&health, Some("health"), "Health", "emblem-favorite-symbolic");
    health.bind_switcher(view_stack);

    let apps = StoandlAppsPage::new();
    apps.bind_client(client);
    view_stack.add_titled_with_icon(&apps, Some("apps"), "Apps", "view-grid-symbolic");
    apps.bind_switcher(view_stack);

    let notifs = StoandlNotificationsPage::new();
    notifs.bind_client(client);
    view_stack.add_titled_with_icon(
        &notifs,
        Some("notifications"),
        "Notifications",
        "preferences-system-notifications-symbolic",
    );
    notifs.bind_switcher(view_stack);

    let settings = StoandlSettingsPage::new();
    settings.bind_client(client);
    view_stack.add_titled_with_icon(&settings, Some("settings"), "Settings", "emblem-system-symbolic");
    settings.bind_switcher(view_stack);
}

#[allow(dead_code)]
fn add_placeholder(
    view_stack: &adw::ViewStack,
    name: &str,
    tab_title: &str,
    icon: &str,
    page_title: &str,
) {
    let status = adw::StatusPage::builder()
        .icon_name(icon)
        .title(page_title)
        .description("Port in progress.")
        .build();
    view_stack.add_titled_with_icon(&status, Some(name), tab_title, icon);
}
