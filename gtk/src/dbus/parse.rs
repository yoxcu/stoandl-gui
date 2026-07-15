//! Pure parsing of the `de.yoxcu.stoandl.Control` wire format.
//!
//! Every reply is either a `kind:message` status string or an `as` array of
//! TAB-separated records. These functions are the single place that logic lives
//! (never in the UI). See `docs/handoff/gtk-rewrite/ARCHITECTURE.md`.

/// A parsed `kind:message` status reply. Split on the **first** colon only —
/// the tail may itself contain colons (URLs, `confirm:<code>`, error text).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Status {
    pub kind: String,
    pub tail: String,
    /// `tail` split on TAB (empty when tail is empty).
    pub fields: Vec<String>,
}

impl Status {
    pub fn ok(&self) -> bool {
        self.kind == "ok"
    }
    pub fn notready(&self) -> bool {
        self.kind == "notready"
    }
    /// `fields[i]` or "" — the daemon omits trailing empties.
    pub fn field(&self, i: usize) -> &str {
        self.fields.get(i).map(String::as_str).unwrap_or("")
    }
}

/// Split a `kind:message` reply. `"ok:a\tb"` → kind `ok`, fields `[a, b]`.
pub fn parse_status(reply: &str) -> Status {
    let (kind, tail) = match reply.find(':') {
        Some(i) => (reply[..i].to_string(), reply[i + 1..].to_string()),
        None => (reply.to_string(), String::new()),
    };
    let fields = if tail.is_empty() {
        Vec::new()
    } else {
        tail.split('\t').map(str::to_string).collect()
    };
    Status { kind, tail, fields }
}

/// Split each `as` element on TAB into its fields.
pub fn parse_records(rows: &[String]) -> Vec<Vec<String>> {
    rows.iter()
        .map(|r| r.split('\t').map(str::to_string).collect())
        .collect()
}

/// Leading contiguous ASCII digits as an int, else -1. Handles `"3000 ms"`.
pub fn parse_percent(s: &str) -> i32 {
    let digits: String = s.chars().take_while(char::is_ascii_digit).collect();
    digits.parse().unwrap_or(-1)
}

/// Split a `ListWatchPrefs` `allowed` field — **pipe**-separated for
/// enum/quicklaunch/color/bool/number-range (NOT comma).
pub fn split_pipe(s: &str) -> Vec<String> {
    if s.is_empty() {
        Vec::new()
    } else {
        s.split('|').map(str::to_string).collect()
    }
}

/// Comma-separated fields (app flags, config-schema options) — the *other*
/// separator, deliberately distinct from `allowed`'s pipes.
pub fn split_comma(s: &str) -> Vec<String> {
    if s.is_empty() {
        Vec::new()
    } else {
        s.split(',').map(str::to_string).collect()
    }
}

/// A number pref's derived range, from an `allowed` like `"0..100"` or
/// `"1000..10000 ms"`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NumberRange {
    pub min: i32,
    pub max: i32,
    pub unit: String,
}

pub fn parse_number_allowed(allowed: &str) -> Option<NumberRange> {
    let (range, unit) = match allowed.split_once(' ') {
        Some((r, u)) => (r, u.trim().to_string()),
        None => (allowed, String::new()),
    };
    let (a, b) = range.split_once("..")?;
    Some(NumberRange {
        min: a.trim().parse().ok()?,
        max: b.trim().parse().ok()?,
        unit,
    })
}

// --- Watch-tab typed row builders ------------------------------------------
// These mirror the Qt StoandlClient parsing exactly (src/StoandlClient.cpp).

/// A `ListWatches` record: `name \t state \t battery \t transport`.
/// `transport` is `ble`|`classic`, empty when disconnected; `connected` is
/// derived from `state == "connected"`. `battery` stays a String ("" = unknown).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WatchRow {
    pub name: String,
    pub state: String,
    pub battery: String,
    pub transport: String,
    pub connected: bool,
}

pub fn parse_watches(rows: &[String]) -> Vec<WatchRow> {
    parse_records(rows)
        .into_iter()
        .map(|f| {
            let g = |i: usize| f.get(i).cloned().unwrap_or_default();
            let state = g(1);
            WatchRow {
                connected: state == "connected",
                name: g(0),
                state,
                battery: g(2),
                transport: g(3),
            }
        })
        .collect()
}

/// `WatchDetails()` → `ok:name\tcode\tmodel\tplatform\ttransport\tfirmware\tserial\tbattery\tlastSync`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WatchDetails {
    pub name: String,
    pub code: String,
    pub model: String,
    pub platform: String,
    pub transport: String,
    pub firmware: String,
    pub serial: String,
    pub battery: String,
    pub last_sync: String,
}

pub fn parse_watch_details(s: &Status) -> Option<WatchDetails> {
    if !s.ok() {
        return None;
    }
    Some(WatchDetails {
        name: s.field(0).to_string(),
        code: s.field(1).to_string(),
        model: s.field(2).to_string(),
        platform: s.field(3).to_string(),
        transport: s.field(4).to_string(),
        firmware: s.field(5).to_string(),
        serial: s.field(6).to_string(),
        battery: s.field(7).to_string(),
        last_sync: s.field(8).to_string(),
    })
}

/// `CheckFirmware()` → `ok:board\tcurrent\tlatest\tasset\t<yes|no>\tsource\tchangelogUrl`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FirmwareInfo {
    pub board: String,
    pub current: String,
    pub latest: String,
    pub asset: String,
    pub update_available: bool,
    pub source: String,
    pub changelog_url: String,
}

pub fn parse_firmware_info(s: &Status) -> Option<FirmwareInfo> {
    if !s.ok() {
        return None;
    }
    Some(FirmwareInfo {
        board: s.field(0).to_string(),
        current: s.field(1).to_string(),
        latest: s.field(2).to_string(),
        asset: s.field(3).to_string(),
        update_available: s.field(4) == "yes",
        source: s.field(5).to_string(),
        changelog_url: s.field(6).to_string(),
    })
}

/// A `ListLanguages` record: `id \t isoLocal \t displayName \t installed(yes|no) \t source`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LanguageRow {
    pub id: String,
    pub iso_local: String,
    pub display_name: String,
    pub installed: bool,
    pub source: String,
}

pub fn parse_languages(rows: &[String]) -> Vec<LanguageRow> {
    parse_records(rows)
        .into_iter()
        .map(|f| {
            let g = |i: usize| f.get(i).cloned().unwrap_or_default();
            LanguageRow {
                id: g(0),
                iso_local: g(1),
                display_name: g(2),
                installed: g(3) == "yes",
                source: g(4),
            }
        })
        .collect()
}

// --- Health-tab typed builders ---------------------------------------------

/// `GetHealthSummary(periodType, offset)` → `ok:` + 20 TAB fields.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct HealthSummary {
    pub steps_total: i32,
    pub steps_avg_per_day: i32,
    pub steps_typical: i32,
    pub distance_km: String,
    pub kcal: i32,
    pub active_min: i32,
    pub sleep_total_min: i32,
    pub sleep_deep_min: i32,
    pub sleep_light_min: i32,
    pub sleep_typical_min: i32,
    pub sleep_bedtime: i64, // epoch seconds; 0 = n/a
    pub sleep_wakeup: i64,
    pub hr_avg: i32,
    pub hr_resting: i32,
    pub hr_current: i32,
    pub hr_min: i32,
    pub hr_max: i32,
    pub hr_available: bool, // watch HAS an HRM (NOT "has readings")
    pub days_with_data: i32,
    pub last_sync: String,
}

fn i(s: &str) -> i32 {
    s.parse().unwrap_or(0)
}
fn l(s: &str) -> i64 {
    s.parse().unwrap_or(0)
}

pub fn parse_health_summary(s: &Status) -> Option<HealthSummary> {
    if !s.ok() {
        return None;
    }
    Some(HealthSummary {
        steps_total: i(s.field(0)),
        steps_avg_per_day: i(s.field(1)),
        steps_typical: i(s.field(2)),
        distance_km: s.field(3).to_string(),
        kcal: i(s.field(4)),
        active_min: i(s.field(5)),
        sleep_total_min: i(s.field(6)),
        sleep_deep_min: i(s.field(7)),
        sleep_light_min: i(s.field(8)),
        sleep_typical_min: i(s.field(9)),
        sleep_bedtime: l(s.field(10)),
        sleep_wakeup: l(s.field(11)),
        hr_avg: i(s.field(12)),
        hr_resting: i(s.field(13)),
        hr_current: i(s.field(14)),
        hr_min: i(s.field(15)),
        hr_max: i(s.field(16)),
        hr_available: s.field(17) == "yes",
        days_with_data: i(s.field(18)),
        last_sync: s.field(19).to_string(),
    })
}

/// A steps bar (hourly for `day`, per-day for week/month): `label \t steps \t typical`.
/// Empty `steps` → value 0, `has_value` false.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct StepBar {
    pub label: String,
    pub value: i32,
    pub has_value: bool,
    pub typical: i32,
}

pub fn parse_step_bars(rows: &[String]) -> Vec<StepBar> {
    parse_records(rows)
        .into_iter()
        .map(|f| {
            let g = |n: usize| f.get(n).map(String::as_str).unwrap_or("");
            let v = g(1);
            StepBar {
                label: g(0).to_string(),
                value: i(v),
                has_value: !v.is_empty(),
                typical: i(g(2)),
            }
        })
        .collect()
}

/// A daily sleep-timeline segment: `startFraction \t widthFraction \t isDeep(0|1)`,
/// fractions of an 18 h window (6 PM → noon). Light first, deep last (drawn on top).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SleepSegment {
    pub start: f64,
    pub width: f64,
    pub deep: bool,
}

pub fn parse_sleep_timeline(rows: &[String]) -> Vec<SleepSegment> {
    parse_records(rows)
        .into_iter()
        .map(|f| {
            let g = |n: usize| f.get(n).map(String::as_str).unwrap_or("");
            SleepSegment {
                start: g(0).parse().unwrap_or(0.0),
                width: g(1).parse().unwrap_or(0.0),
                deep: i(g(2)) != 0,
            }
        })
        .collect()
}

/// A week/month sleep bar: `label \t totalMin \t deepMin`. `value` = total minutes.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SleepBar {
    pub label: String,
    pub value: i32, // total minutes (bar height)
    pub deep: i32,  // deep minutes (stacked base)
    pub has_value: bool,
}

pub fn parse_sleep_bars(rows: &[String]) -> Vec<SleepBar> {
    parse_records(rows)
        .into_iter()
        .map(|f| {
            let g = |n: usize| f.get(n).map(String::as_str).unwrap_or("");
            let total = i(g(1));
            SleepBar {
                label: g(0).to_string(),
                value: total,
                deep: i(g(2)),
                has_value: total > 0,
            }
        })
        .collect()
}

/// A daily HR sample: `minuteOfDay(0-1439) \t bpm`.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct HeartSample {
    pub minute: i32,
    pub bpm: i32,
}

pub fn parse_heart_samples(rows: &[String]) -> Vec<HeartSample> {
    parse_records(rows)
        .into_iter()
        .map(|f| {
            let g = |n: usize| f.get(n).map(String::as_str).unwrap_or("");
            HeartSample { minute: i(g(0)), bpm: i(g(1)) }
        })
        .collect()
}

/// A week/month HR bar: `label \t avgBpm`. Empty avg → value 0, `has_value` false.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct HeartBar {
    pub label: String,
    pub value: i32, // avg bpm
    pub has_value: bool,
}

pub fn parse_heart_bars(rows: &[String]) -> Vec<HeartBar> {
    parse_records(rows)
        .into_iter()
        .map(|f| {
            let g = |n: usize| f.get(n).map(String::as_str).unwrap_or("");
            let v = g(1);
            HeartBar {
                label: g(0).to_string(),
                value: i(v),
                has_value: !v.is_empty(),
            }
        })
        .collect()
}

// --- Apps-tab typed builders -----------------------------------------------

/// A `ListApps` record: `uuid \t type \t order \t flags \t title \t developer \t version`.
/// `flags` is a comma-joined subset of {active, sideloaded, config, system, synced}.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AppRow {
    pub uuid: String,
    pub app_type: String,
    pub order: i32,
    pub title: String,
    pub developer: String,
    pub version: String,
    pub active: bool,
    pub system: bool,
    pub config: bool, // has a config webview
    pub sideloaded: bool,
    pub synced: bool,
    pub is_face: bool,
}

pub fn parse_apps(rows: &[String]) -> Vec<AppRow> {
    let mut out: Vec<AppRow> = parse_records(rows)
        .into_iter()
        .map(|f| {
            let g = |n: usize| f.get(n).map(String::as_str).unwrap_or("");
            let app_type = g(1).to_string();
            let flags = split_comma(g(3));
            let has = |name: &str| flags.iter().any(|x| x == name);
            AppRow {
                uuid: g(0).to_string(),
                order: g(2).parse().unwrap_or(0),
                title: g(4).to_string(),
                developer: g(5).to_string(),
                version: g(6).to_string(),
                active: has("active"),
                system: has("system"),
                config: has("config"),
                sideloaded: has("sideloaded"),
                synced: has("synced"),
                is_face: app_type == "watchface",
                app_type,
            }
        })
        .collect();
    // Stable order by the locker `order` field so the list doesn't jump around.
    out.sort_by_key(|a| a.order);
    out
}

/// An `ExtList` record: `name \t installed|missing \t enabled|disabled \t
/// running|stopped \t config(none|url|schema) \t description \t author \t version`.
/// `runtime_state` merges the live `ExtensionStateChanged` override (a
/// quarantined/exited ext the polled `running` flag can't reveal).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ExtRow {
    pub name: String,
    pub installed: bool,
    pub enabled: bool,
    pub running: bool,
    pub config: String,
    pub has_config: bool,
    pub description: String,
    pub author: String,
    pub version: String,
    pub runtime_state: String, // running|stopped|exited|quarantined
}

pub fn parse_ext_list(
    rows: &[String],
    overrides: &std::collections::HashMap<String, String>,
) -> Vec<ExtRow> {
    parse_records(rows)
        .into_iter()
        .map(|f| {
            let g = |n: usize| f.get(n).map(String::as_str).unwrap_or("");
            let name = g(0).to_string();
            let cfg = g(4);
            let config = if cfg.is_empty() { "none".to_string() } else { cfg.to_string() };
            let running = g(3) == "running";
            // Only quarantined/exited override the polled running/stopped; a bare
            // `ready` maps back to running/stopped (it's less specific).
            let runtime_state = match overrides.get(&name).map(String::as_str) {
                Some("quarantined") => "quarantined".to_string(),
                Some("exited") => "exited".to_string(),
                _ if running => "running".to_string(),
                _ => "stopped".to_string(),
            };
            ExtRow {
                installed: g(1) == "installed",
                enabled: g(2) == "enabled",
                running,
                has_config: config == "url" || config == "schema",
                config,
                description: g(5).to_string(),
                author: g(6).to_string(),
                version: g(7).to_string(),
                runtime_state,
                name,
            }
        })
        .collect()
}

/// `OpenConfig`'s odd reply: a bare URL, empty (`none`), or a `kind:tail` status.
/// Returns `(kind, url, msg)`.
pub fn parse_open_config(raw: &str) -> (String, String, String) {
    if raw.is_empty() {
        return ("none".into(), String::new(), String::new());
    }
    if raw.starts_with("http://") || raw.starts_with("https://") || raw.starts_with("file://") {
        return ("ok".into(), raw.to_string(), String::new());
    }
    let s = parse_status(raw);
    if s.ok() {
        ("ok".into(), s.tail, String::new())
    } else {
        (s.kind, String::new(), s.tail)
    }
}

/// A field in an extension's JSON config schema (`ExtConfigSchema`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ExtField {
    pub key: String,
    pub field_type: String, // bool|string|int|enum
    pub label: String,
    pub secret: bool,
    pub options: Vec<String>,
}

pub fn parse_ext_schema(json: &str) -> Vec<ExtField> {
    let Ok(serde_json::Value::Array(arr)) = serde_json::from_str::<serde_json::Value>(json) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|v| {
            let o = v.as_object()?;
            let s = |k: &str| o.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string();
            Some(ExtField {
                key: s("key"),
                field_type: s("type"),
                label: s("label"),
                secret: o.get("secret").and_then(|x| x.as_bool()).unwrap_or(false),
                options: o
                    .get("options")
                    .and_then(|x| x.as_array())
                    .map(|a| a.iter().filter_map(|s| s.as_str().map(String::from)).collect())
                    .unwrap_or_default(),
            })
        })
        .collect()
}

// --- Notifications-tab typed builders --------------------------------------

/// A `NotifList` record: `name \t muteLabel \t color \t icon \t vibe \t lastNotified`.
/// `muted` = the mute label isn't `never`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NotifApp {
    pub name: String,
    pub mute: String,
    pub muted: bool,
    pub color: String,
    pub icon: String,
    pub vibe: String,
    pub last_notified: String,
}

pub fn parse_notif_list(rows: &[String]) -> Vec<NotifApp> {
    parse_records(rows)
        .into_iter()
        .map(|f| {
            let g = |n: usize| f.get(n).map(String::as_str).unwrap_or("");
            let mute = g(1).to_string();
            NotifApp {
                muted: mute != "never",
                name: g(0).to_string(),
                color: g(2).to_string(),
                icon: g(3).to_string(),
                vibe: g(4).to_string(),
                last_notified: g(5).to_string(),
                mute,
            }
        })
        .collect()
}

/// A `NotifListFilters` record: `pattern \t action(allow|block)`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NotifFilter {
    pub pattern: String,
    pub action: String,
}

pub fn parse_notif_filters(rows: &[String]) -> Vec<NotifFilter> {
    parse_records(rows)
        .into_iter()
        .map(|f| {
            let g = |n: usize| f.get(n).map(String::as_str).unwrap_or("");
            NotifFilter { pattern: g(0).to_string(), action: g(1).to_string() }
        })
        .collect()
}

/// A `GetSyncStatus` record: `service \t enabled \t available \t lastSync`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SyncStatus {
    pub service: String,
    pub enabled: bool,
    pub available: bool,
    pub last_sync: String,
}

pub fn parse_sync_status(rows: &[String]) -> Vec<SyncStatus> {
    parse_records(rows)
        .into_iter()
        .map(|f| {
            let g = |n: usize| f.get(n).map(String::as_str).unwrap_or("");
            SyncStatus {
                service: g(0).to_string(),
                enabled: g(1) == "enabled",
                available: g(2) == "available",
                last_sync: g(3).to_string(),
            }
        })
        .collect()
}

// --- Settings-tab typed builders -------------------------------------------

/// A `ListWatchPrefs` record: `id \t type \t current \t default \t allowed \t
/// flags \t name \t description`. type ∈ {bool,number,enum,quicklaunch,color}.
/// `allowed` is **pipe**-separated (options for enum/quicklaunch/color, a
/// "true|false" for bool, and "min..max[ unit]" for number). Number min/max/unit
/// are pre-derived. `current_int` takes the leading digits ("3000 ms" → 3000).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WatchPref {
    pub id: String,
    pub pref_type: String,
    pub current: String,
    pub current_bool: bool,
    pub current_int: i32,
    pub default: String,
    pub allowed: Vec<String>,
    pub flags: Vec<String>,
    pub debug: bool,
    pub name: String,
    pub description: String,
    // number only (0/100/"" otherwise).
    pub min: i32,
    pub max: i32,
    pub unit: String,
}

pub fn parse_watch_prefs(rows: &[String]) -> Vec<WatchPref> {
    parse_records(rows)
        .into_iter()
        .map(|f| {
            let g = |n: usize| f.get(n).map(String::as_str).unwrap_or("");
            let pref_type = g(1).to_string();
            let current = g(2).to_string();
            let allowed_raw = g(4);
            let flags = split_comma(g(5));
            let (mut min, mut max, mut unit) = (0, 100, String::new());
            if pref_type == "number" {
                if let Some(nr) = parse_number_allowed(allowed_raw) {
                    min = nr.min.max(0);
                    max = nr.max;
                    unit = nr.unit;
                }
            }
            WatchPref {
                debug: flags.iter().any(|x| x == "debug"),
                current_bool: current == "true",
                current_int: parse_percent(&current),
                id: g(0).to_string(),
                default: g(3).to_string(),
                allowed: split_pipe(allowed_raw),
                name: g(6).to_string(),
                description: g(7).to_string(),
                pref_type,
                current,
                flags,
                min,
                max,
                unit,
            }
        })
        .collect()
}

/// A `GetConfigSchema` record: `key \t type \t label \t options(comma) \t desc`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ConfigField {
    pub key: String,
    pub field_type: String,
    pub label: String,
    pub options: Vec<String>,
    pub desc: String,
}

pub fn parse_config_schema(rows: &[String]) -> Vec<ConfigField> {
    parse_records(rows)
        .into_iter()
        .map(|f| {
            let g = |n: usize| f.get(n).map(String::as_str).unwrap_or("");
            ConfigField {
                key: g(0).to_string(),
                field_type: g(1).to_string(),
                label: g(2).to_string(),
                options: split_comma(g(3)),
                desc: g(4).to_string(),
            }
        })
        .collect()
}

/// `GetConfig` records: `key \t value` → an ordered list of pairs.
pub fn parse_config_values(rows: &[String]) -> Vec<(String, String)> {
    parse_records(rows)
        .into_iter()
        .map(|f| {
            (
                f.first().cloned().unwrap_or_default(),
                f.get(1).cloned().unwrap_or_default(),
            )
        })
        .collect()
}

/// A `ListCalendars` record: `id \t name \t enabled|disabled \t accountId`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Calendar {
    pub id: String,
    pub name: String,
    pub enabled: bool,
    pub account_id: String,
}

pub fn parse_calendars(rows: &[String]) -> Vec<Calendar> {
    parse_records(rows)
        .into_iter()
        .map(|f| {
            let g = |n: usize| f.get(n).map(String::as_str).unwrap_or("");
            Calendar {
                id: g(0).to_string(),
                name: g(1).to_string(),
                enabled: g(2) == "enabled",
                account_id: g(3).to_string(),
            }
        })
        .collect()
}

/// A `ListCalendarSources` record: `id \t type \t url \t username \t label`
/// (password is write-only — never returned).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CalendarSource {
    pub id: String,
    pub source_type: String,
    pub url: String,
    pub username: String,
    pub label: String,
}

pub fn parse_calendar_sources(rows: &[String]) -> Vec<CalendarSource> {
    parse_records(rows)
        .into_iter()
        .map(|f| {
            let g = |n: usize| f.get(n).map(String::as_str).unwrap_or("");
            CalendarSource {
                id: g(0).to_string(),
                source_type: g(1).to_string(),
                url: g(2).to_string(),
                username: g(3).to_string(),
                label: g(4).to_string(),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_first_colon_only() {
        let s = parse_status("confirm:481516");
        assert_eq!(s.kind, "confirm");
        assert_eq!(s.tail, "481516");

        let s = parse_status("error:pairing failed: try again");
        assert_eq!(s.kind, "error");
        assert_eq!(s.tail, "pairing failed: try again");
    }

    #[test]
    fn status_tab_fields() {
        let s = parse_status("ok:Pebble Time\t87");
        assert!(s.ok());
        assert_eq!(s.fields, vec!["Pebble Time", "87"]);
        assert_eq!(s.field(1), "87");
        assert_eq!(s.field(5), "");
    }

    #[test]
    fn status_no_colon_and_empty_tail() {
        assert_eq!(parse_status("ok").kind, "ok");
        assert!(parse_status("ok").fields.is_empty());
        assert!(parse_status("ok:").fields.is_empty());
        assert!(parse_status("notready:").notready());
    }

    #[test]
    fn records_split_on_tab() {
        let rows = vec!["a\tb\tc".to_string(), "d\te".to_string()];
        assert_eq!(parse_records(&rows), vec![vec!["a", "b", "c"], vec!["d", "e"]]);
    }

    #[test]
    fn percent_leading_digits() {
        assert_eq!(parse_percent("3000 ms"), 3000);
        assert_eq!(parse_percent("42"), 42);
        assert_eq!(parse_percent("off"), -1);
        assert_eq!(parse_percent(""), -1);
    }

    #[test]
    fn allowed_separators() {
        assert_eq!(split_pipe("true|false"), vec!["true", "false"]);
        assert_eq!(split_pipe(""), Vec::<String>::new());
        assert_eq!(split_comma("active,config,system"), vec!["active", "config", "system"]);
    }

    #[test]
    fn number_range() {
        assert_eq!(
            parse_number_allowed("1000..10000 ms"),
            Some(NumberRange { min: 1000, max: 10000, unit: "ms".into() })
        );
        assert_eq!(
            parse_number_allowed("0..100"),
            Some(NumberRange { min: 0, max: 100, unit: String::new() })
        );
        assert_eq!(parse_number_allowed("nonsense"), None);
    }

    #[test]
    fn watches_and_connected_flag() {
        let rows = vec![
            "Pebble Time\tconnected\t87\tble".to_string(),
            "Pebble 2\tdisconnected\t\t".to_string(),
            "Kickstarter\tdisconnected".to_string(), // trailing empties omitted
        ];
        let w = parse_watches(&rows);
        assert_eq!(w.len(), 3);
        assert!(w[0].connected);
        assert_eq!(w[0].battery, "87");
        assert_eq!(w[0].transport, "ble");
        assert!(!w[1].connected);
        assert_eq!(w[1].transport, "");
        assert!(!w[2].connected);
        assert_eq!(w[2].battery, ""); // missing field → ""
    }

    #[test]
    fn watch_details_ok_and_notready() {
        let s = parse_status("ok:Pebble Time\tPTR\tPebble Time\tbasalt\tBLE\t4.4.2\tQ402\t87\t2m ago");
        let d = parse_watch_details(&s).unwrap();
        assert_eq!(d.name, "Pebble Time");
        assert_eq!(d.platform, "basalt");
        assert_eq!(d.serial, "Q402");
        assert_eq!(d.last_sync, "2m ago");
        assert!(parse_watch_details(&parse_status("notready:")).is_none());
    }

    #[test]
    fn firmware_info_update_flag() {
        let s = parse_status("ok:silk\t4.4.0\t4.4.2\tfw.pbz\tyes\trebble\thttps://x/y:z");
        let f = parse_firmware_info(&s).unwrap();
        assert!(f.update_available);
        assert_eq!(f.latest, "4.4.2");
        assert_eq!(f.changelog_url, "https://x/y:z"); // tail colons preserved
        let s2 = parse_status("ok:silk\t4.4.2\t4.4.2\tfw.pbz\tno\trebble\t");
        assert!(!parse_firmware_info(&s2).unwrap().update_available);
        assert!(parse_firmware_info(&parse_status("error:boom")).is_none());
    }

    #[test]
    fn languages_installed_flag() {
        let rows = vec![
            "en_US\tEnglish\tEnglish (US)\tyes\trebble".to_string(),
            "de_DE\tDeutsch\tGerman\tno\tgithub".to_string(),
        ];
        let l = parse_languages(&rows);
        assert!(l[0].installed);
        assert_eq!(l[0].display_name, "English (US)");
        assert!(!l[1].installed);
        assert_eq!(l[1].source, "github");
    }

    #[test]
    fn health_summary_fields() {
        let tail = "8000\t7500\t9000\t6.1\t420\t45\t451\t120\t331\t430\t1719800000\t1719828000\t62\t54\t68\t48\t142\tyes\t7\t2 min ago";
        let s = parse_status(&format!("ok:{tail}"));
        let h = parse_health_summary(&s).unwrap();
        assert_eq!(h.steps_total, 8000);
        assert_eq!(h.distance_km, "6.1");
        assert_eq!(h.sleep_total_min, 451);
        assert_eq!(h.sleep_bedtime, 1719800000);
        assert!(h.hr_available);
        assert_eq!(h.hr_resting, 54);
        assert_eq!(h.last_sync, "2 min ago");
        assert!(parse_health_summary(&parse_status("notready:")).is_none());
    }

    #[test]
    fn health_series_builders() {
        let steps = parse_step_bars(&["Mon\t7432\t8000".into(), "Tue\t\t8000".into()]);
        assert_eq!(steps[0].value, 7432);
        assert!(steps[0].has_value);
        assert_eq!(steps[0].typical, 8000);
        assert!(!steps[1].has_value); // empty steps → no value

        let seg = parse_sleep_timeline(&["0.1\t0.05\t0".into(), "0.15\t0.2\t1".into()]);
        assert!((seg[0].start - 0.1).abs() < 1e-9);
        assert!(!seg[0].deep);
        assert!(seg[1].deep);

        let sb = parse_sleep_bars(&["Mon\t451\t120".into(), "Tue\t0\t0".into()]);
        assert_eq!(sb[0].value, 451);
        assert_eq!(sb[0].deep, 120);
        assert!(sb[0].has_value);
        assert!(!sb[1].has_value); // total 0 → no value

        let hs = parse_heart_samples(&["540\t62".into(), "600\t70".into()]);
        assert_eq!(hs[0].minute, 540);
        assert_eq!(hs[1].bpm, 70);

        let hb = parse_heart_bars(&["Mon\t64".into(), "Tue\t".into()]);
        assert!(hb[0].has_value);
        assert_eq!(hb[0].value, 64);
        assert!(!hb[1].has_value); // empty avg → no reading
    }

    #[test]
    fn apps_flags_face_and_order() {
        let rows = vec![
            "uuid-b\twatchapp\t2\tconfig\tWeather\tPebble\t1.2".to_string(),
            "uuid-a\twatchface\t1\tactive,system,synced\tTicToc\tPebble\t".to_string(),
        ];
        let a = parse_apps(&rows);
        // sorted by order → TicToc (1) first.
        assert_eq!(a[0].title, "TicToc");
        assert!(a[0].is_face && a[0].active && a[0].system && a[0].synced);
        assert!(!a[0].config);
        assert!(!a[1].is_face && a[1].config);
        assert_eq!(a[1].version, "1.2");
    }

    #[test]
    fn ext_list_runtime_override() {
        let mut ov = std::collections::HashMap::new();
        ov.insert("Signal".to_string(), "quarantined".to_string());
        ov.insert("Ready One".to_string(), "ready".to_string()); // maps back to running
        let rows = vec![
            "Signal\tinstalled\tenabled\trunning\tschema\tSecure msgr\tOWS\t1.0".to_string(),
            "Ready One\tinstalled\tenabled\trunning\turl\tX\tY\t2".to_string(),
            "Off\tinstalled\tdisabled\tstopped\tnone\tZ\t\t".to_string(),
        ];
        let e = parse_ext_list(&rows, &ov);
        assert_eq!(e[0].runtime_state, "quarantined"); // override wins over running
        assert!(e[0].has_config); // schema
        assert_eq!(e[1].runtime_state, "running"); // bare `ready` → polled running
        assert_eq!(e[2].config, "none");
        assert!(!e[2].has_config);
        assert!(!e[2].enabled);
    }

    #[test]
    fn ext_schema_json() {
        let json = r#"[{"key":"token","type":"string","label":"Token","secret":true},
                       {"key":"modem","type":"enum","label":"Modem","options":["MM","oFono"]}]"#;
        let f = parse_ext_schema(json);
        assert_eq!(f[0].key, "token");
        assert!(f[0].secret);
        assert_eq!(f[1].field_type, "enum");
        assert_eq!(f[1].options, vec!["MM", "oFono"]);
        assert!(parse_ext_schema("not json").is_empty());
    }

    #[test]
    fn notif_and_sync_builders() {
        let apps = parse_notif_list(&[
            "Messages\tnever\t#00f\tBell\tDouble\t2m ago".into(),
            "Slack\talways\t\tDefault\tStandard\t".into(),
        ]);
        assert!(!apps[0].muted);
        assert_eq!(apps[0].vibe, "Double");
        assert!(apps[1].muted); // mute != "never"

        let filters = parse_notif_filters(&["OTP.*\tblock".into(), "boss\tallow".into()]);
        assert_eq!(filters[0].action, "block");
        assert_eq!(filters[1].pattern, "boss");

        let ss = parse_sync_status(&[
            "notifications\tenabled\tavailable\tjust now".into(),
            "weather\tdisabled\tunavailable\t".into(),
        ]);
        assert!(ss[0].enabled && ss[0].available);
        assert!(!ss[1].enabled && !ss[1].available);
    }

    #[test]
    fn watch_prefs_types() {
        let rows = vec![
            "backlight\tnumber\t3000 ms\t5000\t1000..10000 ms\t\tBacklight\tHow long\t".into(),
            "vibes\tbool\ttrue\tfalse\ttrue|false\tdebug\tVibrate\t".into(),
            "font\tenum\tGothic 18\tGothic 24\tGothic 18|Gothic 24|Bitham\t\tFont\t".into(),
        ];
        let p = parse_watch_prefs(&rows);
        assert_eq!(p[0].pref_type, "number");
        assert_eq!(p[0].current_int, 3000); // leading digits of "3000 ms"
        assert_eq!(p[0].min, 1000);
        assert_eq!(p[0].max, 10000);
        assert_eq!(p[0].unit, "ms");
        assert!(p[1].current_bool && p[1].debug); // flags has "debug"
        assert_eq!(p[2].allowed, vec!["Gothic 18", "Gothic 24", "Bitham"]); // pipe-split
    }

    #[test]
    fn config_calendars_sources() {
        let sch = parse_config_schema(&["theme\tenum\tTheme\tlight,dark,auto\tUI theme".into()]);
        assert_eq!(sch[0].options, vec!["light", "dark", "auto"]); // comma-split
        let vals = parse_config_values(&["theme\tdark".into(), "port\t9000".into()]);
        assert_eq!(vals[0], ("theme".into(), "dark".into()));

        let cals = parse_calendars(&["c1\tWork\tenabled\tacc1".into(), "c2\tHome\tdisabled\tacc1".into()]);
        assert!(cals[0].enabled && !cals[1].enabled);
        assert_eq!(cals[0].account_id, "acc1");

        let src = parse_calendar_sources(&["s1\tcaldav\thttps://x\tbob\tWork CalDAV".into()]);
        assert_eq!(src[0].source_type, "caldav");
        assert_eq!(src[0].username, "bob");
    }
}
