//! Compile-time constants shared across the app.

/// Application id: Wayland app_id, GApplication id, GResource prefix base,
/// .desktop / metainfo / icon name. Identical to the Qt build (see `data/`).
pub const APP_ID: &str = "de.yoxcu.stoandl.gui";

/// GResource base path (mirrors APP_ID as a path). Referenced literally in the
/// `#[template(resource = …)]` attributes; kept here as the single source of truth.
#[allow(dead_code)]
pub const RESOURCE_PREFIX: &str = "/de/yoxcu/stoandl/gui";

// --- D-Bus contract: de.yoxcu.stoandl.Control on the session bus ------------
pub const DBUS_NAME: &str = "de.yoxcu.stoandl";
pub const DBUS_PATH: &str = "/de/yoxcu/stoandl";
pub const DBUS_IFACE: &str = "de.yoxcu.stoandl.Control";

/// Default blocking-call timeout (ms). FindWatch overrides to 20s.
pub const CALL_TIMEOUT_MS: i32 = 10_000;
pub const FIND_TIMEOUT_MS: i32 = 20_000;
