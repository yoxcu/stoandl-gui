//! The 5 nav destinations. Each is added to the shell `Adw.ViewStack` in
//! `install()` (Watch first → tab 0). Real pages are composite-template widgets;
//! not-yet-ported tabs get an `Adw.StatusPage` placeholder.

mod apps;
mod battery;
mod health;
mod heartbeat;
mod notifications;
mod settings;
mod watch;

pub use apps::StoandlAppsPage;
pub use health::StoandlHealthPage;
pub use notifications::StoandlNotificationsPage;
pub use settings::StoandlSettingsPage;
pub use watch::StoandlWatchPage;

use std::time::{SystemTime, UNIX_EPOCH};

use adw::prelude::*;
use gtk::glib;

use crate::dbus::StoandlClient;

/// Escape a data-derived string for use as an Adw row title/subtitle — those
/// parse Pango markup, so a bare `&`/`<` from an app or extension name errors.
pub(crate) fn esc(s: &str) -> String {
    glib::markup_escape_text(s).to_string()
}

/// A daemon-side temp path for a diagnostics artefact (screenshot / logs / core
/// dump). The GUI is co-located with the daemon, so a local tmp path is valid.
pub(crate) fn temp_path(prefix: &str, ext: &str) -> String {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    glib::tmp_dir()
        .join(format!("{prefix}-{ts}.{ext}"))
        .to_string_lossy()
        .into_owned()
}

/// An activatable action row (leading icon, optional destructive styling). An
/// empty `subtitle` is hidden by Adw, so callers with a self-explanatory label
/// pass `""`.
pub(crate) fn action_row<F: Fn() + 'static>(
    label: &str,
    subtitle: &str,
    icon: &str,
    danger: bool,
    on_activate: F,
) -> adw::ActionRow {
    let row = adw::ActionRow::builder()
        .title(label)
        .subtitle(subtitle)
        .activatable(true)
        .build();
    let img = gtk::Image::from_icon_name(icon);
    row.add_prefix(&img);
    if danger {
        row.add_css_class("error");
    }
    row.connect_activated(move |_| on_activate());
    row
}

/// A boolean row. Callers pass an already-escaped title/subtitle (they come from
/// daemon data), and a closure that applies the new value.
pub(crate) fn switch_row<F: Fn(bool) + 'static>(
    title: &str,
    subtitle: &str,
    on: bool,
    apply: F,
) -> adw::SwitchRow {
    let row = adw::SwitchRow::builder()
        .title(title)
        .subtitle(subtitle)
        .active(on)
        .build();
    row.connect_active_notify(move |r| apply(r.is_active()));
    row
}

/// A fixed-option row. `cur` selects the initial option (first if it doesn't
/// match); `apply` receives the chosen option verbatim, since every schema on
/// this interface takes its own option value back.
pub(crate) fn combo_row<F: Fn(&str) + 'static>(
    title: &str,
    subtitle: &str,
    options: &[String],
    cur: &str,
    apply: F,
) -> adw::ComboRow {
    let model = gtk::StringList::new(&options.iter().map(String::as_str).collect::<Vec<_>>());
    let row = adw::ComboRow::builder()
        .title(title)
        .subtitle(subtitle)
        .model(&model)
        .build();
    row.set_selected(options.iter().position(|o| o == cur).unwrap_or(0) as u32);
    let opts = options.to_vec();
    row.connect_selected_notify(move |r| {
        if let Some(v) = opts.get(r.selected() as usize) {
            apply(v);
        }
    });
    row
}

/// A bounded integer row (stepper + clamp — the HIG widget for numeric-with-range).
/// `unit` is appended to the title when non-empty, since AdwSpinRow has no unit slot.
/// `apply` is called on every step; the caller is expected to debounce it (see
/// `debounce` below) because a spin fires per step and each apply rebuilds the row.
pub(crate) fn spin_row<F: Fn(i64) + 'static>(
    title: &str,
    subtitle: &str,
    min: i64,
    max: i64,
    cur: f64,
    apply: F,
) -> adw::SpinRow {
    // ~100 steps across the range so a wide one stays navigable.
    let step = (((max - min).max(1)) as f64 / 100.0).round().max(1.0);
    let adj = gtk::Adjustment::new(
        cur.clamp(min as f64, max as f64),
        min as f64,
        max as f64,
        step,
        step * 10.0,
        0.0,
    );
    let row = adw::SpinRow::new(Some(&adj), step, 0);
    row.set_title(title);
    if !subtitle.is_empty() {
        row.set_subtitle(subtitle);
    }
    adj.connect_value_changed(move |a| apply(a.value().round() as i64));
    row
}

/// Coalesce a burst of writes into one, ~500 ms after the user stops.
///
/// Every numeric row on this interface needs it: the spin fires on each step and
/// each apply re-fetches and rebuilds the very control being dragged. `slot` holds
/// the single pending timer for that form, so a new tick replaces the old one and a
/// rebuild can cancel it (a timer that fires into a destroyed row would re-apply a
/// stale value).
pub(crate) fn debounce<F: FnOnce() + 'static>(
    slot: &std::cell::RefCell<Option<glib::SourceId>>,
    f: F,
) -> glib::SourceId {
    if let Some(t) = slot.borrow_mut().take() {
        t.remove();
    }
    glib::timeout_add_local_once(std::time::Duration::from_millis(500), f)
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
    view_stack.add_titled_with_icon(&health, Some("health"), "Health", "stoandl-heart-symbolic");
    health.bind_switcher(view_stack);

    let apps = StoandlAppsPage::new();
    apps.bind_client(client);
    view_stack.add_titled_with_icon(&apps, Some("apps"), "Apps", "view-grid-symbolic");
    apps.bind_switcher(view_stack);

    let notifs = StoandlNotificationsPage::new();
    notifs.bind_client(client);
    // Tab labelled "Alerts" (short, no wrap on narrow); the stack page name stays
    // "notifications" (internal id). Renamed on main (feat(nav)).
    view_stack.add_titled_with_icon(
        &notifs,
        Some("notifications"),
        "Alerts",
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
