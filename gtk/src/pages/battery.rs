//! The Battery insights page (`StoandlBatteryPage`) — GTK4/libadwaita port of
//! `qml/BatteryPage.qml`. Pushed from the Watch tab as its own `NavigationPage`.
//! A hero level gauge, a battery-%-over-time line chart (with a notification-
//! density overlay), per-interval drain bars, a power-attribution donut, and
//! headline trend tiles. Data: `BatteryInsights`/`BatteryHistory`/
//! `BatteryActivity`/`BatteryPower` (heartbeat source preferred). All charts are
//! Cairo `DrawingArea`s (see `widgets::chart`); parsing lives in the client.
//!
//! Lifecycle: a fresh page is built on every open and dropped on pop, so it just
//! reloads once on `bind_client` (plus on each range switch) — no client-signal
//! subscriptions. Battery metrics move on the hourly heartbeat anyway. The two
//! subscriptions it *does* take are on the process-global `StyleManager`
//! (dark/accent → recolour the donut); those are disconnected on `unrealize` so
//! repeated opens don't accumulate dead handlers on the singleton.

use std::cell::{Cell, OnceCell, RefCell};
use std::time::{SystemTime, UNIX_EPOCH};

use adw::prelude::*;
use adw::subclass::prelude::*;
use gtk::{gdk, glib, CompositeTemplate};

use crate::dbus::{BatteryActivity, BatteryInsights, BatteryPowerSlice, BatterySample, StoandlClient};
use crate::widgets::chart::{self, draw_battery_line, draw_donut, draw_drain_bars, hsla, with_alpha};

fn dbg_smoke(msg: &str) {
    if std::env::var_os("STOANDL_SMOKE_MS").is_some() {
        eprintln!("stoandl-smoke: {msg}");
    }
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Colour a battery level: green healthy/charging, amber low, red critical.
fn level_color(pct: i32, charging: bool, p: &chart::Palette) -> gdk::RGBA {
    if charging {
        p.success
    } else if pct <= 15 {
        p.error
    } else if pct <= 35 {
        p.warning
    } else {
        p.success
    }
}

/// libadwaita text class matching `level_color` (for the big % label / chip).
fn level_class(pct: i32, charging: bool) -> &'static str {
    if charging {
        "success"
    } else if pct <= 15 {
        "error"
    } else if pct <= 35 {
        "warning"
    } else {
        "success"
    }
}

/// Stable, theme-aware hue per power-attribution category (fixed so a slice keeps
/// its colour when others drop out; hue-rotation fallback for anything else).
fn slice_color(cat: &str, i: usize, dark: bool) -> gdk::RGBA {
    let hue = match cat {
        "System" => 0.68,
        "Display" => 0.12,
        "Vibration" => 0.95,
        "Speaker" => 0.78,
        "Heart rate" => 0.02,
        "Bluetooth" => 0.58,
        "CPU" => 0.40,
        _ => (i as f64 * 0.16) % 1.0,
    };
    hsla(hue, 0.55, if dark { 0.62 } else { 0.46 }, 1.0)
}

fn source_label(src: &str) -> &'static str {
    match src {
        "heartbeat" => "from the watch's hourly analytics heartbeat",
        "gatt" => "from the BLE battery level",
        _ => "",
    }
}

fn rel_age(epoch: i64, now: i64) -> String {
    if epoch <= 0 {
        return "—".into();
    }
    let d = now - epoch;
    if d < 60 {
        "just now".into()
    } else if d < 3600 {
        format!("{}m ago", d / 60)
    } else if d < 86400 {
        format!("{}h ago", d / 3600)
    } else {
        format!("{}d ago", d / 86400)
    }
}

/// "13:04" for a 24 h window, otherwise "Jul 5".
fn fmt_axis(epoch: f64, range_seconds: i64) -> String {
    let Ok(dt) = glib::DateTime::from_unix_local(epoch as i64) else {
        return String::new();
    };
    if range_seconds <= 24 * 3600 {
        dt.format("%H:%M").map(|g| g.to_string()).unwrap_or_default()
    } else {
        let mon = dt.format("%b").map(|g| g.to_string()).unwrap_or_default();
        format!("{} {}", mon, dt.day_of_month())
    }
}

/// A start · mid · now x-axis strip (labels at frac 0 / 0.5 / 1).
#[derive(Clone)]
pub struct AxisRow {
    row: gtk::Box,
    start: gtk::Label,
    mid: gtk::Label,
    now: gtk::Label,
}

/// Dynamic widgets built once, updated on each reload.
#[derive(Clone)]
pub struct Cards {
    // hero
    level_label: gtk::Label,
    charging_icon: gtk::Image,
    status_chip: gtk::Label,
    gauge: gtk::DrawingArea,
    voltage_tile: gtk::Box,
    voltage_val: gtk::Label,
    time_tile: gtk::Box,
    time_val: gtk::Label,
    // history
    hist_header: gtk::Label,
    hist_empty: gtk::Widget,
    hist_row: gtk::Box,
    hist_area: gtk::DrawingArea,
    hist_axis: AxisRow,
    notif_caption: gtk::Label,
    // drain
    drain_empty: gtk::Widget,
    drain_row: gtk::Box,
    drain_area: gtk::DrawingArea,
    drain_peak: gtk::Label,
    drain_axis: AxisRow,
    // power
    power_empty: gtk::Widget,
    power_row: gtk::Box,
    donut_area: gtk::DrawingArea,
    legend: gtk::Box,
    power_drain: gtk::Label,
    power_caption: gtk::Label,
    // trends
    trend_discharge: gtk::Label,
    trend_charges: gtk::Label,
    trend_lastcharged: gtk::Label,
    trend_range: gtk::Label,
    // footnote
    source_line: gtk::Label,
}

mod imp {
    use super::*;

    #[derive(CompositeTemplate, Default)]
    #[template(resource = "/de/yoxcu/stoandl/gui/ui/battery.ui")]
    pub struct StoandlBatteryPage {
        #[template_child]
        pub range_bar: TemplateChild<gtk::Box>,
        #[template_child]
        pub range_24h: TemplateChild<gtk::ToggleButton>,
        #[template_child]
        pub range_7d: TemplateChild<gtk::ToggleButton>,
        #[template_child]
        pub range_30d: TemplateChild<gtk::ToggleButton>,
        #[template_child]
        pub battery_stack: TemplateChild<gtk::Stack>,
        #[template_child]
        pub empty_status: TemplateChild<adw::StatusPage>,
        #[template_child]
        pub content_box: TemplateChild<gtk::Box>,

        pub client: OnceCell<StoandlClient>,
        pub cards: OnceCell<Cards>,

        // StyleManager (dark/accent) subscriptions, disconnected on unrealize.
        pub style_handlers: RefCell<Vec<glib::SignalHandlerId>>,

        pub range_seconds: Cell<i64>,
        pub reload_gen: Cell<u64>,

        // snapshot for the draw funcs + tiles.
        pub level: Cell<i32>,
        pub charging: Cell<bool>,
        pub now_sec: Cell<f64>,
        pub range_start: Cell<f64>,
        pub max_drop: Cell<f64>,
        pub insights: RefCell<Option<BatteryInsights>>,
        pub insights_kind: RefCell<String>,
        pub history: RefCell<Vec<BatterySample>>,
        pub activity: RefCell<Vec<BatteryActivity>>,
        pub power: RefCell<Vec<(BatteryPowerSlice, gdk::RGBA)>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for StoandlBatteryPage {
        const NAME: &'static str = "StoandlBatteryPage";
        type Type = super::StoandlBatteryPage;
        type ParentType = adw::NavigationPage;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }
        fn instance_init(obj: &glib::subclass::InitializingObject<Self>) {
            obj.init_template();
        }
    }

    impl ObjectImpl for StoandlBatteryPage {
        fn constructed(&self) {
            self.parent_constructed();
            self.range_seconds.set(24 * 3600);
        }
    }
    impl WidgetImpl for StoandlBatteryPage {}
    impl NavigationPageImpl for StoandlBatteryPage {}
}

glib::wrapper! {
    pub struct StoandlBatteryPage(ObjectSubclass<imp::StoandlBatteryPage>)
        @extends adw::NavigationPage, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl Default for StoandlBatteryPage {
    fn default() -> Self {
        Self::new()
    }
}

impl StoandlBatteryPage {
    pub fn new() -> Self {
        glib::Object::new()
    }

    fn client(&self) -> StoandlClient {
        self.imp().client.get().expect("client bound").clone()
    }

    /// Store the client, build the cards, wire the range switcher, kick a reload.
    pub fn bind_client(&self, client: &StoandlClient) {
        self.imp().client.set(client.clone()).ok();
        self.build_cards();

        for (btn, secs) in [
            (self.imp().range_24h.get(), 24 * 3600i64),
            (self.imp().range_7d.get(), 7 * 86400),
            (self.imp().range_30d.get(), 30 * 86400),
        ] {
            btn.connect_toggled(glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |b| {
                    if b.is_active() {
                        page.set_range(secs);
                    }
                }
            ));
        }

        // redraw charts on theme / accent change (slice colours are dark-aware).
        // The page is rebuilt per open, so keep the handler ids and drop them on
        // unrealize — otherwise each open leaves dead closures on the global
        // StyleManager singleton.
        let sm = adw::StyleManager::default();
        let h_dark = sm.connect_dark_notify(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.on_theme_changed()
        ));
        let h_accent = sm.connect_accent_color_notify(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.on_theme_changed()
        ));
        self.imp().style_handlers.borrow_mut().extend([h_dark, h_accent]);
        self.connect_unrealize(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| {
                let sm = adw::StyleManager::default();
                for id in page.imp().style_handlers.borrow_mut().drain(..) {
                    sm.disconnect(id);
                }
            }
        ));

        self.spawn_reload();
    }

    fn set_range(&self, secs: i64) {
        if self.imp().range_seconds.get() == secs {
            return;
        }
        self.imp().range_seconds.set(secs);
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
            self.imp().insights.replace(None);
            self.imp().insights_kind.replace(String::new());
            self.imp().history.replace(Vec::new());
            self.imp().activity.replace(Vec::new());
            self.imp().power.replace(Vec::new());
            self.update_ui();
            return;
        }

        let now = now_secs();
        let range = self.imp().range_seconds.get();
        let start = now - range;

        let (status, insights) = c.battery_insights("").await;
        let history = c.battery_history("", start).await;
        let activity = c.battery_activity("", start).await;
        let power_raw = c.battery_power("", start).await;

        // A newer reload superseded us while awaiting — drop this stale snapshot.
        if self.imp().reload_gen.get() != generation {
            return;
        }

        let dark = adw::StyleManager::default().is_dark();
        let power: Vec<(BatteryPowerSlice, gdk::RGBA)> = power_raw
            .into_iter()
            .enumerate()
            .map(|(i, s)| {
                let col = slice_color(&s.category, i, dark);
                (s, col)
            })
            .collect();
        let max_drop = activity.iter().fold(0.0f64, |m, a| m.max(a.drop));

        self.imp().now_sec.set(now as f64);
        self.imp().range_start.set(start as f64);
        self.imp().max_drop.set(max_drop);
        self.imp().level.set(insights.as_ref().map(|i| i.level.round() as i32).unwrap_or(0));
        self.imp().charging.set(insights.as_ref().map(|i| i.charging).unwrap_or(false));
        self.imp().insights.replace(insights);
        self.imp().insights_kind.replace(status.kind.clone());
        self.imp().history.replace(history);
        self.imp().activity.replace(activity);
        self.imp().power.replace(power);
        self.update_ui();
    }

    fn on_theme_changed(&self) {
        // Slice colours depend on light/dark; recompute them, then redraw.
        let dark = adw::StyleManager::default().is_dark();
        let mut power = self.imp().power.borrow_mut();
        for (i, entry) in power.iter_mut().enumerate() {
            entry.1 = slice_color(&entry.0.category, i, dark);
        }
        drop(power);
        self.rebuild_legend();
        self.redraw_charts();
    }

    fn redraw_charts(&self) {
        if let Some(c) = self.imp().cards.get() {
            c.gauge.queue_draw();
            c.hist_area.queue_draw();
            c.drain_area.queue_draw();
            c.donut_area.queue_draw();
        }
    }

    /// Headless smoke hook: cycle to the 7-day range so the multi-day draw path
    /// (wider bars, date axis) renders too. No-op outside the smoke test.
    pub fn smoke_exercise(&self) {
        if std::env::var_os("STOANDL_SMOKE_MS").is_none() {
            return;
        }
        self.set_range(7 * 86400);
        dbg_smoke("exercised battery 7-day range");
    }

    // --- update ---------------------------------------------------------------

    fn update_axis(&self, axis: &AxisRow) {
        let start = self.imp().range_start.get();
        let now = self.imp().now_sec.get();
        let range = self.imp().range_seconds.get();
        let span = (now - start).max(1.0);
        axis.start.set_label(&fmt_axis(start, range));
        axis.mid.set_label(&fmt_axis(start + 0.5 * span, range));
        axis.now.set_label("now");
    }

    fn update_ui(&self) {
        let imp = self.imp();
        let up = self.client().daemon_up();
        let has = imp.insights.borrow().is_some();

        imp.range_bar.set_visible(up && has);
        imp.battery_stack
            .set_visible_child_name(if has { "content" } else { "empty" });

        if !has {
            let kind = imp.insights_kind.borrow().clone();
            let (icon, title, desc) = if !up {
                (
                    "battery-symbolic",
                    "Daemon not running",
                    "Start it with: systemctl --user start stoandl".to_string(),
                )
            } else if kind == "notready" {
                (
                    "battery-missing-symbolic",
                    "No battery data",
                    "Battery capture is off, or no watch is connected.".to_string(),
                )
            } else {
                (
                    "battery-symbolic",
                    "No battery data yet",
                    "Insights build up as the watch reports. The analytics heartbeat arrives about once an hour."
                        .to_string(),
                )
            };
            imp.empty_status.set_icon_name(Some(icon));
            imp.empty_status.set_title(title);
            imp.empty_status.set_description(Some(&desc));
            dbg_smoke(&format!("battery ui: empty (up={up}, kind={kind})"));
            return;
        }

        let Some(cards) = imp.cards.get() else { return };
        let insights = imp.insights.borrow().clone().unwrap();
        let level = imp.level.get();
        let charging = imp.charging.get();
        let now = imp.now_sec.get() as i64;
        let range = imp.range_seconds.get();

        // HERO.
        cards.level_label.set_label(&format!("{level}%"));
        for c in ["success", "warning", "error"] {
            cards.level_label.remove_css_class(c);
            cards.status_chip.remove_css_class(c);
        }
        cards.level_label.add_css_class(level_class(level, charging));
        cards.charging_icon.set_visible(charging);
        let chip = if charging {
            "Charging"
        } else if level >= 98 {
            "Full"
        } else {
            "Discharging"
        };
        cards.status_chip.set_label(chip);
        cards.status_chip.remove_css_class("dim-label");
        if charging {
            cards.status_chip.add_css_class("success");
        } else {
            cards.status_chip.add_css_class("dim-label");
        }
        cards.gauge.queue_draw();

        let has_v = !insights.voltage.is_empty();
        cards.voltage_tile.set_visible(has_v);
        cards.voltage_val.set_label(&format!("{} V", insights.voltage));
        let has_time = !charging && !insights.hours_remaining.is_empty();
        cards.time_tile.set_visible(has_time);
        cards.time_val.set_label(&format!("~{} h", insights.hours_remaining));

        // HISTORY.
        let days = range / 86400;
        cards.hist_header.set_label(&format!(
            "Over the last {}",
            if range == 24 * 3600 { "24 hours".to_string() } else { format!("{days} days") }
        ));
        let hist_ok = imp.history.borrow().len() >= 2;
        cards.hist_empty.set_visible(!hist_ok);
        cards.hist_row.set_visible(hist_ok);
        cards.hist_axis.row.set_visible(hist_ok);
        if hist_ok {
            self.update_axis(&cards.hist_axis);
        }
        cards.hist_area.queue_draw();

        // notification-density caption.
        let has_notifs = imp.activity.borrow().iter().any(|a| a.notif > 0);
        cards.notif_caption.set_visible(has_notifs);

        // DRAIN.
        let drain_ok = !imp.activity.borrow().is_empty();
        cards.drain_empty.set_visible(!drain_ok);
        cards.drain_row.set_visible(drain_ok);
        cards.drain_axis.row.set_visible(drain_ok);
        let md = imp.max_drop.get();
        cards
            .drain_peak
            .set_label(&if md > 0.0 { format!("{md:.1}%") } else { "0%".to_string() });
        if drain_ok {
            self.update_axis(&cards.drain_axis);
        }
        cards.drain_area.queue_draw();

        // POWER.
        let power_ok = !imp.power.borrow().is_empty();
        cards.power_empty.set_visible(!power_ok);
        cards.power_row.set_visible(power_ok);
        cards.power_caption.set_visible(power_ok);
        // Anchored drain total: sum of the per-subsystem estimates; only meaningful
        // (and shown) when the window actually discharged.
        let drain_total: f64 = imp.power.borrow().iter().map(|(s, _)| s.est_drain_pct).sum();
        cards.power_drain.set_visible(power_ok && drain_total > 0.0);
        cards
            .power_drain
            .set_label(&format!("≈ {drain_total:.1}% battery over this window"));
        self.rebuild_legend();
        cards.donut_area.queue_draw();

        // TRENDS.
        cards.trend_discharge.set_label(&if charging {
            "—".to_string()
        } else {
            format!("{:.1} %/h", insights.discharge_per_hour)
        });
        cards.trend_charges.set_label(&format!("{}", insights.charge_sessions));
        cards
            .trend_lastcharged
            .set_label(&rel_age(insights.last_charged_epoch, now));
        cards.trend_range.set_label(&format!(
            "{}–{}%",
            insights.min24h.round() as i64,
            insights.max24h.round() as i64
        ));

        // FOOTNOTE.
        cards.source_line.set_label(&format!(
            "{} · {} samples",
            source_label(&insights.source),
            insights.sample_count
        ));

        dbg_smoke(&format!(
            "battery ui: level={level}, charging={charging}, hist={}, activity={}, power={}, max_drop={md:.1}",
            imp.history.borrow().len(),
            imp.activity.borrow().len(),
            imp.power.borrow().len(),
        ));
    }

    fn rebuild_legend(&self) {
        let Some(cards) = self.imp().cards.get() else { return };
        while let Some(child) = cards.legend.first_child() {
            cards.legend.remove(&child);
        }
        for (slice, color) in self.imp().power.borrow().iter() {
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
            let swatch = gtk::DrawingArea::new();
            swatch.set_content_width(13);
            swatch.set_content_height(13);
            swatch.set_valign(gtk::Align::Center);
            let col = *color;
            swatch.set_draw_func(move |_, cr, w, h| {
                cr.set_source_rgba(col.red() as f64, col.green() as f64, col.blue() as f64, col.alpha() as f64);
                rounded_rect(cr, 0.0, 0.0, w as f64, h as f64, 2.0);
                let _ = cr.fill();
            });
            let name = gtk::Label::builder()
                .label(super::esc(&slice.category))
                .xalign(0.0)
                .hexpand(true)
                .ellipsize(gtk::pango::EllipsizeMode::End)
                .build();
            let share = gtk::Label::new(Some(&format!("{}%", slice.share.round() as i64)));
            share.add_css_class("caption-heading");
            row.append(&swatch);
            row.append(&name);
            row.append(&share);
            cards.legend.append(&row);
        }
    }

    // --- chart draw funcs -----------------------------------------------------

    fn draw_gauge(&self, area: &gtk::DrawingArea, cr: &gtk::cairo::Context, w: i32, h: i32) {
        let p = chart::palette(area);
        let (level, charging) = (self.imp().level.get(), self.imp().charging.get());
        let (w, h) = (w as f64, h as f64);
        let radius = h / 4.0;
        // track outline.
        let border = with_alpha(p.fg, 0.25);
        rounded_rect(cr, 0.5, 0.5, w - 1.0, h - 1.0, radius);
        cr.set_source_rgba(border.red() as f64, border.green() as f64, border.blue() as f64, border.alpha() as f64);
        cr.set_line_width(1.0);
        let _ = cr.stroke();
        // fill (like the QML: a minimum radius*2 nub, clipped to the gauge on
        // very narrow allocations rather than clamped to a negative width).
        let frac = (level as f64 / 100.0).clamp(0.0, 1.0);
        let fw = ((w - 4.0) * frac).max(radius * 2.0);
        let col = level_color(level, charging, &p);
        rounded_rect(cr, 2.0, 2.0, fw, h - 4.0, radius);
        cr.set_source_rgba(col.red() as f64, col.green() as f64, col.blue() as f64, col.alpha() as f64);
        let _ = cr.fill();
    }

    fn draw_history(&self, area: &gtk::DrawingArea, cr: &gtk::cairo::Context, w: i32, h: i32) {
        let p = chart::palette(area);
        let hist: Vec<(f64, f64)> =
            self.imp().history.borrow().iter().map(|s| (s.ts as f64, s.level)).collect();
        let notif: Vec<(f64, i32)> =
            self.imp().activity.borrow().iter().map(|a| (a.ts as f64, a.notif)).collect();
        let t0 = self.imp().range_start.get();
        let span = (self.imp().now_sec.get() - t0).max(1.0);
        draw_battery_line(cr, w as f64, h as f64, &hist, &notif, t0, span, p.accent, p.fg);
    }

    fn draw_drain(&self, area: &gtk::DrawingArea, cr: &gtk::cairo::Context, w: i32, h: i32) {
        let p = chart::palette(area);
        let bars: Vec<(f64, f64)> =
            self.imp().activity.borrow().iter().map(|a| (a.ts as f64, a.drop)).collect();
        let t0 = self.imp().range_start.get();
        let span = (self.imp().now_sec.get() - t0).max(1.0);
        let max_drop = self.imp().max_drop.get();
        draw_drain_bars(cr, w as f64, h as f64, &bars, t0, span, max_drop, p.warning, p.fg);
    }

    fn draw_power(&self, _area: &gtk::DrawingArea, cr: &gtk::cairo::Context, w: i32, h: i32) {
        let slices: Vec<(f64, gdk::RGBA)> =
            self.imp().power.borrow().iter().map(|(s, c)| (s.share, *c)).collect();
        draw_donut(cr, w as f64, h as f64, &slices);
    }

    // --- card construction ----------------------------------------------------

    fn build_cards(&self) {
        let content = self.imp().content_box.get();

        // ---- Hero ----
        let hero = card_body();
        let head = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        let level_label = gtk::Label::new(None);
        level_label.add_css_class("title-1");
        let charging_icon = gtk::Image::from_icon_name("battery-full-charging-symbolic");
        charging_icon.add_css_class("success");
        charging_icon.set_pixel_size(24);
        charging_icon.set_valign(gtk::Align::Center);
        charging_icon.set_visible(false);
        let head_spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        head_spacer.set_hexpand(true);
        let status_chip = gtk::Label::new(None);
        status_chip.set_valign(gtk::Align::Center);
        status_chip.add_css_class("status-chip");
        head.append(&level_label);
        head.append(&charging_icon);
        head.append(&head_spacer);
        head.append(&status_chip);
        hero.append(&head);

        let gauge = gtk::DrawingArea::new();
        gauge.set_content_height(16);
        gauge.set_hexpand(true);
        gauge.set_draw_func(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |a, cr, w, h| page.draw_gauge(a, cr, w, h)
        ));
        hero.append(&gauge);

        let tiles = gtk::Box::new(gtk::Orientation::Horizontal, 24);
        let (voltage_tile, voltage_val) = stat_tile("voltage");
        let (time_tile, time_val) = stat_tile("time remaining");
        tiles.append(&voltage_tile);
        tiles.append(&time_tile);
        let tiles_spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        tiles_spacer.set_hexpand(true);
        tiles.append(&tiles_spacer);
        hero.append(&tiles);
        content.append(&hero);

        // ---- History chart ----
        let hist_header = heading("");
        content.append(&hist_header);
        let hist_card = card_body();
        let hist_empty =
            placeholder("Not enough samples yet", "The chart fills in as readings arrive.");
        hist_card.append(&hist_empty);

        let hist_row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        hist_row.append(&y_gutter(&["100%", "50%", "0%"]).0);
        let hist_area = chart_area(176);
        hist_area.set_draw_func(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |a, cr, w, h| page.draw_history(a, cr, w, h)
        ));
        hist_row.append(&hist_area);
        hist_card.append(&hist_row);
        let hist_axis = axis_row();
        hist_card.append(&hist_axis.row);
        content.append(&hist_card);

        let notif_caption = caption(
            "Shaded bands mark hours with notifications — denser bands, more notifications.",
        );
        content.append(&notif_caption);

        // ---- Drain chart ----
        content.append(&heading("Battery drain"));
        let drain_card = card_body();
        let drain_empty = placeholder(
            "No drain data yet",
            "Each bar is the battery used in one hourly analytics heartbeat.",
        );
        drain_card.append(&drain_empty);

        let drain_row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        let (drain_gutter, mut drain_peaks) = y_gutter(&["0%", "0%"]);
        let drain_peak = drain_peaks.remove(0); // top label is the peak
        drain_row.append(&drain_gutter);
        let drain_area = chart_area(112);
        drain_area.set_draw_func(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |a, cr, w, h| page.draw_drain(a, cr, w, h)
        ));
        drain_row.append(&drain_area);
        drain_card.append(&drain_row);
        let drain_axis = axis_row();
        drain_card.append(&drain_axis.row);
        content.append(&drain_card);

        // ---- Power donut ----
        content.append(&heading("What drew power"));
        let power_card = card_body();
        let power_empty = placeholder(
            "No usage breakdown yet",
            "Built from the hourly analytics heartbeat (Bluetooth LE watches).",
        );
        power_card.append(&power_empty);

        let power_row = gtk::Box::new(gtk::Orientation::Horizontal, 18);
        let donut_area = gtk::DrawingArea::new();
        donut_area.set_content_width(128);
        donut_area.set_content_height(128);
        donut_area.set_valign(gtk::Align::Start);
        donut_area.set_draw_func(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |a, cr, w, h| page.draw_power(a, cr, w, h)
        ));
        power_row.append(&donut_area);
        let legend = gtk::Box::new(gtk::Orientation::Vertical, 6);
        legend.set_hexpand(true);
        legend.set_valign(gtk::Align::Center);
        power_row.append(&legend);
        power_card.append(&power_row);
        // Anchored drain total ("≈ N% battery over this window") — the headline the
        // energy-weighted (drain-anchored) pie exists to justify; hidden when the
        // window never discharged (only the pie shares are meaningful then).
        let power_drain = gtk::Label::builder()
            .xalign(0.0)
            .hexpand(true)
            .wrap(true)
            .visible(false)
            .build();
        power_card.append(&power_drain);
        let power_caption = caption(
            "Estimated share of battery drain (modeled current × on-time), anchored to the \
             watch’s measured SoC drop — not metered energy. “Display” is the backlight; \
             “System” is the always-on floor.",
        );
        power_card.append(&power_caption);
        content.append(&power_card);

        // ---- Trends ----
        content.append(&heading("Trends"));
        let trends_card = card_body();
        let grid = gtk::Grid::new();
        grid.set_column_spacing(24);
        grid.set_row_spacing(12);
        grid.set_column_homogeneous(true);
        let (t1, trend_discharge) = stat_tile("discharge rate");
        let (t2, trend_charges) = stat_tile("charges · 7 days");
        let (t3, trend_lastcharged) = stat_tile("last charged");
        let (t4, trend_range) = stat_tile("range · 24 h");
        grid.attach(&t1, 0, 0, 1, 1);
        grid.attach(&t2, 1, 0, 1, 1);
        grid.attach(&t3, 0, 1, 1, 1);
        grid.attach(&t4, 1, 1, 1, 1);
        trends_card.append(&grid);
        content.append(&trends_card);

        // ---- Source footnote ----
        let source_line = caption("");
        source_line.set_margin_start(6);
        content.append(&source_line);

        let cards = Cards {
            level_label,
            charging_icon,
            status_chip,
            gauge,
            voltage_tile,
            voltage_val,
            time_tile,
            time_val,
            hist_header,
            hist_empty: hist_empty.upcast(),
            hist_row,
            hist_area,
            hist_axis,
            notif_caption,
            drain_empty: drain_empty.upcast(),
            drain_row,
            drain_area,
            drain_peak,
            drain_axis,
            power_empty: power_empty.upcast(),
            power_row,
            donut_area,
            legend,
            power_drain,
            power_caption,
            trend_discharge,
            trend_charges,
            trend_lastcharged,
            trend_range,
            source_line,
        };
        self.imp().cards.set(cards).ok();
    }
}

// --- small widget builders ---------------------------------------------------

/// An empty `.card` box with padding (background/border from libadwaita).
fn card_body() -> gtk::Box {
    let card = gtk::Box::new(gtk::Orientation::Vertical, 12);
    card.add_css_class("card");
    card.add_css_class("section-card");
    card
}

/// A section heading label (bold, left-aligned) with a little top margin.
fn heading(text: &str) -> gtk::Label {
    let l = gtk::Label::builder().xalign(0.0).label(text).build();
    l.add_css_class("heading");
    l.set_margin_top(6);
    l
}

/// A dim wrapping caption (small print under a card / footnotes).
fn caption(text: &str) -> gtk::Label {
    let l = gtk::Label::builder().xalign(0.0).wrap(true).label(text).build();
    l.add_css_class("dim-label");
    l.add_css_class("caption");
    l
}

/// An inline "not enough data" placeholder (dim icon + heading + explanation).
fn placeholder(title: &str, explanation: &str) -> gtk::Box {
    let b = gtk::Box::new(gtk::Orientation::Vertical, 4);
    b.set_halign(gtk::Align::Center);
    b.set_margin_top(12);
    b.set_margin_bottom(12);
    let t = gtk::Label::new(Some(title));
    t.add_css_class("heading");
    t.add_css_class("dim-label");
    let e = gtk::Label::builder().label(explanation).wrap(true).justify(gtk::Justification::Center).build();
    e.add_css_class("caption");
    e.add_css_class("dim-label");
    b.append(&t);
    b.append(&e);
    b
}

/// A value-over-label stat tile (bold value, dim caption).
fn stat_tile(label: &str) -> (gtk::Box, gtk::Label) {
    let b = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let value = gtk::Label::builder().xalign(0.0).ellipsize(gtk::pango::EllipsizeMode::End).build();
    value.add_css_class("title-4");
    let l = gtk::Label::builder().xalign(0.0).label(label).build();
    l.add_css_class("dim-label");
    l.add_css_class("caption");
    b.append(&value);
    b.append(&l);
    (b, value)
}

/// A y-axis gutter column: top-to-bottom labels with fill between them.
fn y_gutter(labels: &[&str]) -> (gtk::Box, Vec<gtk::Label>) {
    let col = gtk::Box::new(gtk::Orientation::Vertical, 0);
    col.set_width_request(34);
    let mut out = Vec::new();
    for (i, txt) in labels.iter().enumerate() {
        if i > 0 {
            let spacer = gtk::Box::new(gtk::Orientation::Vertical, 0);
            spacer.set_vexpand(true);
            col.append(&spacer);
        }
        let l = gtk::Label::builder().xalign(1.0).label(*txt).build();
        l.add_css_class("dim-label");
        l.add_css_class("caption");
        col.append(&l);
        out.push(l);
    }
    (col, out)
}

/// A start · mid · now x-axis strip aligned under a chart (past the y-gutter).
fn axis_row() -> AxisRow {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    row.set_margin_start(40);
    let mk = || {
        let l = gtk::Label::new(None);
        l.add_css_class("dim-label");
        l.add_css_class("caption");
        l
    };
    let start = mk();
    start.set_xalign(0.0);
    let mid = mk();
    mid.set_hexpand(true);
    mid.set_halign(gtk::Align::Center);
    let now = mk();
    now.set_xalign(1.0);
    row.append(&start);
    row.append(&mid);
    row.append(&now);
    AxisRow { row, start, mid, now }
}

fn chart_area(height: i32) -> gtk::DrawingArea {
    let a = gtk::DrawingArea::new();
    a.set_content_height(height);
    a.set_hexpand(true);
    a
}

/// A rounded-rectangle sub-path (caller sets the source + fills/strokes).
fn rounded_rect(cr: &gtk::cairo::Context, x: f64, y: f64, w: f64, h: f64, r: f64) {
    if w <= 0.0 || h <= 0.0 {
        return; // degenerate allocation — don't emit backwards arcs
    }
    let r = r.min(w / 2.0).min(h / 2.0).max(0.0);
    let pi = std::f64::consts::PI;
    cr.new_sub_path();
    cr.arc(x + w - r, y + r, r, -pi / 2.0, 0.0);
    cr.arc(x + w - r, y + h - r, r, 0.0, pi / 2.0);
    cr.arc(x + r, y + h - r, r, pi / 2.0, pi);
    cr.arc(x + r, y + r, r, pi, 1.5 * pi);
    cr.close_path();
}
