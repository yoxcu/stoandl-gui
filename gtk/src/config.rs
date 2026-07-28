//! Compile-time constants shared across the app.

/// Application id: Wayland app_id, GApplication id (single-instance bus name),
/// .desktop / metainfo / icon name. Distinct from the Kirigami build's
/// `de.yoxcu.stoandl.gui` so both variants install and run side by side (see `data/`).
pub const APP_ID: &str = "de.yoxcu.stoandl.gui.gtk";

/// GResource base path. Deliberately NOT derived from APP_ID: it is an app-internal
/// path referenced literally in every `#[template(resource = …)]` attribute and in
/// resources.gresource.xml, so it stays `…/gui` (unversioned by variant) — the `.gtk`
/// suffix only needs to reach the user-visible identity above, not the bundle layout.
/// Pinned as the GtkApplication `resource-base-path` in `application.rs` so it stays
/// decoupled from APP_ID.
pub const RESOURCE_PREFIX: &str = "/de/yoxcu/stoandl/gui";

// --- D-Bus contract: de.yoxcu.stoandl.Control on the session bus ------------
pub const DBUS_NAME: &str = "de.yoxcu.stoandl";
pub const DBUS_PATH: &str = "/de/yoxcu/stoandl";
pub const DBUS_IFACE: &str = "de.yoxcu.stoandl.Control";

/// Default blocking-call timeout (ms). FindWatch overrides to 20s.
pub const CALL_TIMEOUT_MS: i32 = 10_000;
pub const FIND_TIMEOUT_MS: i32 = 20_000;
