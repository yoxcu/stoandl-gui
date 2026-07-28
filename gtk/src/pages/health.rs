//! The Health tab (`StoandlHealthPage`) — a read-only, period-based dashboard
//! (port of `qml/HealthPage.qml`). One period control (Daily/Weekly/Monthly + a
//! navigator) drives three sections (steps / sleep / heart rate). Daily shows
//! rich per-day charts; Weekly/Monthly show per-day bars. Charts are Cairo
//! `DrawingArea`s (see `widgets::chart`); date/time formatting uses `glib::DateTime`.

use std::cell::{Cell, OnceCell, RefCell};

use adw::prelude::*;
use adw::subclass::prelude::*;
use gtk::{glib, CompositeTemplate};

use crate::dbus::{
    HealthSummary, HeartBar, HeartSample, SleepBar, SleepSegment, StepBar, StoandlClient,
};
use crate::widgets::chart::{
    self, draw_hr_line, draw_metric_bars, draw_sleep_timeline, with_alpha, BarDatum, BarsOpts,
    HeightScale, HrPoint, Segment, TickFmt,
};
use crate::window::StoandlWindow;

fn dbg_smoke(msg: &str) {
    if std::env::var_os("STOANDL_SMOKE_MS").is_some() {
        eprintln!("stoandl-smoke: {msg}");
    }
}

fn max_offset_for(pt: &str) -> i32 {
    match pt {
        "day" => 30,
        "week" => 12,
        _ => 11,
    }
}

fn fmt_min(total: i32) -> String {
    let t = total.max(0);
    format!("{}h {:02}m", t / 60, t % 60)
}

fn fmt_clock(epoch: i64) -> String {
    if epoch <= 0 {
        return "—".into();
    }
    let Ok(dt) = glib::DateTime::from_unix_local(epoch) else {
        return "—".into();
    };
    let (h, m) = (dt.hour(), dt.minute());
    let ap = if h < 12 { "AM" } else { "PM" };
    let h12 = {
        let x = h % 12;
        if x == 0 {
            12
        } else {
            x
        }
    };
    format!("{h12}:{m:02} {ap}")
}

fn fmt_dt(dt: &glib::DateTime, f: &str) -> String {
    dt.format(f).map(|g| g.to_string()).unwrap_or_default()
}

/// "Mon 3 Jul" — Qt's `ddd d MMM` (day not zero/space-padded, unlike `%e`).
fn fmt_day_wd(dt: &glib::DateTime) -> String {
    format!("{} {} {}", fmt_dt(dt, "%a"), dt.day_of_month(), fmt_dt(dt, "%b"))
}

/// "3 Jul" — Qt's `d MMM`.
fn fmt_day(dt: &glib::DateTime) -> String {
    format!("{} {}", dt.day_of_month(), fmt_dt(dt, "%b"))
}

/// Dynamic widgets built once into the content box, updated on each reload.
#[derive(Clone)]
pub struct Cards {
    // steps
    steps_headline: gtk::Label,
    steps_unit: gtk::Label,
    steps_typical: gtk::Label,
    steps_area: gtk::DrawingArea,
    steps_tiles: gtk::Box,
    tile_distance: gtk::Label,
    tile_cal: gtk::Label,
    tile_active: gtk::Label,
    steps_total_label: gtk::Label,
    // sleep
    sleep_headline: gtk::Label,
    sleep_unit: gtk::Label,
    sleep_range: gtk::Label,
    sleep_fallback: gtk::Label,
    sleep_empty: gtk::Label,
    sleep_timeline_area: gtk::DrawingArea,
    sleep_bars_area: gtk::DrawingArea,
    sleep_legend: gtk::Box,
    sleep_deep_label: gtk::Label,
    sleep_light_label: gtk::Label,
    sleep_typical_legend: gtk::Label,
    sleep_typical_period: gtk::Label,
    // heart
    hr_card: gtk::Box,
    hr_stats: gtk::Box,
    hr_resting: gtk::Box,
    hr_resting_val: gtk::Label,
    hr_avg: gtk::Box,
    hr_avg_val: gtk::Label,
    hr_min: gtk::Box,
    hr_min_val: gtk::Label,
    hr_max: gtk::Box,
    hr_max_val: gtk::Label,
    hr_empty: gtk::Label,
    hr_area: gtk::DrawingArea,
}

mod imp {
    use super::*;

    #[derive(CompositeTemplate, Default)]
    #[template(resource = "/de/yoxcu/stoandl/gui/ui/health.ui")]
    pub struct StoandlHealthPage {
        #[template_child]
        pub sync_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub day_btn: TemplateChild<gtk::ToggleButton>,
        #[template_child]
        pub week_btn: TemplateChild<gtk::ToggleButton>,
        #[template_child]
        pub month_btn: TemplateChild<gtk::ToggleButton>,
        #[template_child]
        pub prev_btn: TemplateChild<gtk::Button>,
        #[template_child]
        pub next_btn: TemplateChild<gtk::Button>,
        #[template_child]
        pub period_label: TemplateChild<gtk::Label>,
        #[template_child]
        pub health_stack: TemplateChild<gtk::Stack>,
        #[template_child]
        pub empty_sync_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub content_box: TemplateChild<gtk::Box>,
        #[template_child]
        pub view_switcher: TemplateChild<adw::ViewSwitcher>,
        #[template_child]
        pub switcher_bar: TemplateChild<adw::ViewSwitcherBar>,

        pub client: OnceCell<StoandlClient>,
        pub cards: OnceCell<Cards>,

        // period state.
        pub period_type: RefCell<String>,
        pub period_offset: Cell<i32>,
        pub reload_gen: Cell<u64>,

        // snapshots (parsed in the client).
        pub summary: RefCell<Option<HealthSummary>>,
        pub step_bars: RefCell<Vec<StepBar>>,
        pub sleep_segments: RefCell<Vec<SleepSegment>>,
        pub sleep_bars: RefCell<Vec<SleepBar>>,
        pub heart_samples: RefCell<Vec<HeartSample>>,
        pub heart_bars: RefCell<Vec<HeartBar>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for StoandlHealthPage {
        const NAME: &'static str = "StoandlHealthPage";
        type Type = super::StoandlHealthPage;
        type ParentType = adw::BreakpointBin;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }
        fn instance_init(obj: &glib::subclass::InitializingObject<Self>) {
            obj.init_template();
        }
    }

    impl ObjectImpl for StoandlHealthPage {
        fn constructed(&self) {
            self.parent_constructed();
            self.period_type.replace("day".to_string());
        }
    }
    impl WidgetImpl for StoandlHealthPage {}
    impl BreakpointBinImpl for StoandlHealthPage {}
}

glib::wrapper! {
    pub struct StoandlHealthPage(ObjectSubclass<imp::StoandlHealthPage>)
        @extends adw::BreakpointBin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl Default for StoandlHealthPage {
    fn default() -> Self {
        Self::new()
    }
}

impl StoandlHealthPage {
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
        self.build_cards();

        // period type (radio toggle group).
        for (btn, kind) in [
            (self.imp().day_btn.get(), "day"),
            (self.imp().week_btn.get(), "week"),
            (self.imp().month_btn.get(), "month"),
        ] {
            btn.connect_toggled(glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |b| {
                    if b.is_active() {
                        page.set_period_type(kind);
                    }
                }
            ));
        }
        // navigator.
        self.imp().prev_btn.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.set_period_offset(page.imp().period_offset.get() + 1)
        ));
        self.imp().next_btn.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.set_period_offset(page.imp().period_offset.get() - 1)
        ));
        // sync.
        for btn in [self.imp().sync_button.get(), self.imp().empty_sync_button.get()] {
            btn.connect_clicked(glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_| page.sync_health()
            ));
        }

        // reload on daemon-up.
        client.connect_notify_local(
            Some("daemon-up"),
            glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_, _| page.spawn_reload()
            ),
        );
        // redraw charts on theme / accent change.
        let sm = adw::StyleManager::default();
        sm.connect_dark_notify(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.redraw_charts()
        ));
        sm.connect_accent_color_notify(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.redraw_charts()
        ));

        self.spawn_reload();
    }

    // --- period model ---------------------------------------------------------

    fn set_period_type(&self, t: &str) {
        if self.imp().period_type.borrow().as_str() == t {
            return;
        }
        self.imp().period_type.replace(t.to_string());
        self.imp().period_offset.set(0);
        self.spawn_reload();
    }

    fn set_period_offset(&self, o: i32) {
        let pt = self.imp().period_type.borrow().clone();
        self.imp().period_offset.set(o.clamp(0, max_offset_for(&pt)));
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
            self.imp().summary.replace(None);
            self.update_ui();
            return;
        }

        let pt = self.imp().period_type.borrow().clone();
        let off = self.imp().period_offset.get();
        let summary = c.health_summary(&pt, off).await;
        let hr_avail = summary.as_ref().map(|s| s.hr_available).unwrap_or(false);
        let steps = c.steps_bars(&pt, off).await;
        let (segs, hr_samples, sbars, hbars) = if pt == "day" {
            let segs = c.sleep_timeline(&pt, off).await;
            let hr = if hr_avail { c.heart_samples(&pt, off).await } else { Vec::new() };
            (segs, hr, Vec::new(), Vec::new())
        } else {
            let sb = c.sleep_bars(&pt, off).await;
            let hb = if hr_avail { c.heart_bars(&pt, off).await } else { Vec::new() };
            (Vec::new(), Vec::new(), sb, hb)
        };

        // A newer reload superseded us while awaiting — drop this stale snapshot.
        if self.imp().reload_gen.get() != generation {
            return;
        }
        self.imp().step_bars.replace(steps);
        self.imp().sleep_segments.replace(segs);
        self.imp().heart_samples.replace(hr_samples);
        self.imp().sleep_bars.replace(sbars);
        self.imp().heart_bars.replace(hbars);
        self.imp().summary.replace(summary);
        self.update_ui();
    }

    fn sync_health(&self) {
        let client = self.client();
        glib::spawn_future_local(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[strong]
            client,
            async move {
                let s = client.sync_health().await;
                if s.ok() {
                    page.toast("Syncing health data…");
                } else if s.kind == "notready" {
                    page.toast("No watch connected");
                } else if s.tail.to_lowercase().contains("not enabled") {
                    page.toast("Health sync is disabled — enable it in Settings");
                } else {
                    let m = if s.tail.is_empty() { s.kind.clone() } else { s.tail.clone() };
                    page.toast(&format!("Health: {m}"));
                }
                page.reload().await;
            }
        ));
    }

    fn period_label(&self) -> String {
        let pt = self.imp().period_type.borrow().clone();
        let off = self.imp().period_offset.get();
        let now = glib::DateTime::now_local().ok();
        match pt.as_str() {
            "day" => {
                if off == 0 {
                    return "Today".into();
                }
                if off == 1 {
                    return "Yesterday".into();
                }
                now.and_then(|n| n.add_days(-off).ok())
                    .map(|d| fmt_day_wd(&d))
                    .unwrap_or_default()
            }
            "week" => {
                if off == 0 {
                    return "This week".into();
                }
                let end = now.and_then(|n| n.add_days(-off * 7).ok());
                let start = end.as_ref().and_then(|e| e.add_days(-6).ok());
                match (start, end) {
                    (Some(s), Some(e)) => format!("{} – {}", fmt_day(&s), fmt_day(&e)),
                    _ => String::new(),
                }
            }
            _ => {
                if off == 0 {
                    return "This month".into();
                }
                now.and_then(|n| n.add_months(-off).ok())
                    .map(|d| fmt_dt(&d, "%B %Y"))
                    .unwrap_or_default()
            }
        }
    }

    fn hr_stats(&self) -> (usize, i32, i32, i32) {
        let s = self.imp().heart_samples.borrow();
        if s.is_empty() {
            return (0, 0, 0, 0);
        }
        let (mut lo, mut hi, mut sum) = (i32::MAX, i32::MIN, 0i64);
        for p in s.iter() {
            lo = lo.min(p.bpm);
            hi = hi.max(p.bpm);
            sum += p.bpm as i64;
        }
        (s.len(), lo, hi, (sum / s.len() as i64) as i32)
    }

    fn sleep_is_fallback(&self, s: &HealthSummary) -> bool {
        if self.imp().period_type.borrow().as_str() != "day" || s.sleep_wakeup <= 0 {
            return false;
        }
        let (Ok(wake), Ok(now)) =
            (glib::DateTime::from_unix_local(s.sleep_wakeup), glib::DateTime::now_local())
        else {
            return false;
        };
        let Some(target) = now.add_days(-self.imp().period_offset.get()).ok() else {
            return false;
        };
        (wake.year(), wake.month(), wake.day_of_month())
            != (target.year(), target.month(), target.day_of_month())
    }

    fn sleep_night_span(&self, s: &HealthSummary) -> String {
        let day = |e: i64| {
            glib::DateTime::from_unix_local(e)
                .ok()
                .map(|d| fmt_dt(&d, "%a").trim_end_matches('.').to_string())
                .unwrap_or_default()
        };
        if s.sleep_bedtime > 0 && s.sleep_wakeup > 0 {
            let (bd, wd) = (day(s.sleep_bedtime), day(s.sleep_wakeup));
            return if bd == wd { bd } else { format!("{bd}–{wd}") };
        }
        glib::DateTime::from_unix_local(s.sleep_wakeup.max(0))
            .ok()
            .map(|d| fmt_day_wd(&d))
            .unwrap_or_default()
    }

    // --- redraw / update ------------------------------------------------------

    fn redraw_charts(&self) {
        if let Some(c) = self.imp().cards.get() {
            c.steps_area.queue_draw();
            c.sleep_timeline_area.queue_draw();
            c.sleep_bars_area.queue_draw();
            c.hr_area.queue_draw();
        }
    }

    fn update_ui(&self) {
        let imp = self.imp();
        let up = self.client().daemon_up();
        let has_data = imp.summary.borrow().is_some();

        imp.health_stack
            .set_visible_child_name(if up && has_data { "content" } else { "empty" });

        let pt = imp.period_type.borrow().clone();
        let off = imp.period_offset.get();
        imp.prev_btn.set_sensitive(off < max_offset_for(&pt));
        imp.next_btn.set_sensitive(off > 0);
        imp.period_label.set_label(&self.period_label());
        imp.sync_button.set_sensitive(up);
        imp.empty_sync_button.set_sensitive(up);

        let (Some(cards), Some(s)) = (imp.cards.get(), imp.summary.borrow().clone()) else {
            return;
        };
        let is_day = pt == "day";

        // STEPS.
        cards
            .steps_headline
            .set_label(&format!("{}", if is_day { s.steps_total } else { s.steps_avg_per_day }));
        cards.steps_unit.set_label(if is_day { "steps" } else { "avg / day" });
        cards.steps_typical.set_visible(s.steps_typical > 0);
        cards.steps_typical.set_label(&format!("Typical {}", s.steps_typical));
        cards.steps_tiles.set_visible(is_day);
        cards.tile_distance.set_label(&format!("{} km", s.distance_km));
        cards.tile_cal.set_label(&format!("{}", s.kcal));
        cards.tile_active.set_label(&format!("{} min", s.active_min));
        cards.steps_total_label.set_visible(!is_day);
        cards
            .steps_total_label
            .set_label(&format!("Total {} over {} days", s.steps_total, s.days_with_data));
        cards.steps_area.queue_draw();

        // SLEEP.
        let have_sleep = s.sleep_total_min > 0;
        let sleep_head = if have_sleep { fmt_min(s.sleep_total_min) } else { "—".to_string() };
        cards.sleep_headline.set_label(&sleep_head);
        cards.sleep_unit.set_label(if is_day { "asleep" } else { "avg / night" });
        cards.sleep_range.set_visible(is_day && have_sleep);
        cards
            .sleep_range
            .set_label(&format!("{} → {}", fmt_clock(s.sleep_bedtime), fmt_clock(s.sleep_wakeup)));
        let fallback = is_day && have_sleep && self.sleep_is_fallback(&s);
        cards.sleep_fallback.set_visible(fallback);
        if fallback {
            cards
                .sleep_fallback
                .set_label(&format!("Last recorded night · {}", self.sleep_night_span(&s)));
        }
        cards.sleep_empty.set_visible(!have_sleep);
        cards.sleep_empty.set_label(if off == 0 {
            "No sleep data yet."
        } else if is_day {
            "No sleep recorded for this day."
        } else {
            "No sleep recorded for this period."
        });
        cards.sleep_timeline_area.set_visible(is_day && have_sleep);
        cards.sleep_bars_area.set_visible(!is_day);
        cards.sleep_legend.set_visible(is_day && have_sleep);
        cards.sleep_deep_label.set_label(&fmt_min(s.sleep_deep_min));
        cards.sleep_light_label.set_label(&fmt_min(s.sleep_light_min));
        cards.sleep_typical_legend.set_visible(is_day && have_sleep && s.sleep_typical_min > 0);
        cards
            .sleep_typical_legend
            .set_label(&format!("Typical {}", fmt_min(s.sleep_typical_min)));
        cards
            .sleep_typical_period
            .set_visible(!is_day && have_sleep && s.sleep_typical_min > 0);
        cards
            .sleep_typical_period
            .set_label(&format!("Typical {} / night", fmt_min(s.sleep_typical_min)));
        cards.sleep_timeline_area.queue_draw();
        cards.sleep_bars_area.queue_draw();

        // HEART.
        cards.hr_card.set_visible(s.hr_available);
        if s.hr_available {
            let (count, lo, hi, avg_day) = self.hr_stats();
            let resting_primary = s.hr_resting > 0;
            let avg_val = if is_day { avg_day } else { s.hr_avg };
            cards.hr_resting.set_visible(resting_primary);
            cards.hr_resting_val.set_label(&format!("{}", s.hr_resting));
            set_primary(&cards.hr_resting_val, resting_primary);
            cards.hr_avg.set_visible(avg_val > 0);
            cards.hr_avg_val.set_label(&format!("{avg_val}"));
            set_primary(&cards.hr_avg_val, !resting_primary && avg_val > 0);
            let show_minmax = is_day && count > 0;
            cards.hr_min.set_visible(show_minmax);
            cards.hr_max.set_visible(show_minmax);
            cards.hr_min_val.set_label(&format!("{lo}"));
            cards.hr_max_val.set_label(&format!("{hi}"));
            let stats_visible = if is_day { count > 0 } else { s.hr_avg > 0 };
            cards.hr_stats.set_visible(stats_visible);
            let empty_visible = if is_day { count == 0 } else { s.hr_avg <= 0 };
            cards.hr_empty.set_visible(empty_visible);
            cards
                .hr_empty
                .set_label(&format!("No heart-rate data for {}.", self.period_label().to_lowercase()));
            cards.hr_area.set_visible(!empty_visible);
            cards.hr_area.queue_draw();
        }

        dbg_smoke(&format!(
            "health ui: period={pt}, steps_total={}, sleep_total={}, hr_available={}, hr_avg={}, step_bars={}, sleep_segs={}, sleep_bars={}, hr_samples={}, hr_bars={}",
            s.steps_total,
            s.sleep_total_min,
            s.hr_available,
            s.hr_avg,
            imp.step_bars.borrow().len(),
            imp.sleep_segments.borrow().len(),
            imp.sleep_bars.borrow().len(),
            imp.heart_samples.borrow().len(),
            imp.heart_bars.borrow().len(),
        ));
    }

    /// Headless smoke hook: switch to the Weekly view so the per-day bar-chart
    /// draw path (steps/sleep/heart bars + navigator) renders too. No-op outside
    /// the smoke test.
    pub fn smoke_exercise(&self) {
        if std::env::var_os("STOANDL_SMOKE_MS").is_none() {
            return;
        }
        self.set_period_type("week");
        dbg_smoke("exercised health weekly view");
    }

    // --- chart draw funcs -----------------------------------------------------

    fn draw_steps(&self, area: &gtk::DrawingArea, cr: &gtk::cairo::Context, w: i32, h: i32) {
        let p = chart::palette(area);
        let is_day = self.imp().period_type.borrow().as_str() == "day";
        let ref_line = if is_day {
            0.0
        } else {
            self.imp().summary.borrow().as_ref().map(|s| s.steps_typical as f64).unwrap_or(0.0)
        };
        let data: Vec<BarDatum> = self
            .imp()
            .step_bars
            .borrow()
            .iter()
            .map(|b| BarDatum {
                value: b.value as f64,
                deep: 0.0,
                has_value: b.has_value,
                label: b.label.clone(),
            })
            .collect();
        let opts = BarsOpts {
            floor_at_min: false,
            ref_line,
            scale: HeightScale::Identity,
            tick: TickFmt::CompactK,
            hourly: is_day,
            bar_color: with_alpha(p.accent, 0.4),
            deep_color: p.accent,
            ref_color: p.accent,
            fg: p.fg,
        };
        draw_metric_bars(cr, w as f64, h as f64, &data, &opts);
    }

    fn draw_sleep_timeline(&self, area: &gtk::DrawingArea, cr: &gtk::cairo::Context, w: i32, h: i32) {
        let p = chart::palette(area);
        let light = p.accent;
        let deep = chart::darker(p.accent, 1.6);
        let data: Vec<Segment> = self
            .imp()
            .sleep_segments
            .borrow()
            .iter()
            .map(|s| Segment { start: s.start, width: s.width, deep: s.deep })
            .collect();
        draw_sleep_timeline(cr, w as f64, h as f64, &data, light, deep, p.fg);
    }

    fn draw_sleep_bars(&self, area: &gtk::DrawingArea, cr: &gtk::cairo::Context, w: i32, h: i32) {
        let p = chart::palette(area);
        let light = p.accent;
        let deep = chart::darker(p.accent, 1.6);
        let data: Vec<BarDatum> = self
            .imp()
            .sleep_bars
            .borrow()
            .iter()
            .map(|b| BarDatum {
                value: b.value as f64,
                deep: b.deep as f64,
                has_value: b.has_value,
                label: b.label.clone(),
            })
            .collect();
        let opts = BarsOpts {
            floor_at_min: false,
            ref_line: 0.0,
            scale: HeightScale::MinutesToHours,
            tick: TickFmt::Hours,
            hourly: false,
            bar_color: light,
            deep_color: deep,
            ref_color: light,
            fg: p.fg,
        };
        draw_metric_bars(cr, w as f64, h as f64, &data, &opts);
    }

    fn draw_hr(&self, area: &gtk::DrawingArea, cr: &gtk::cairo::Context, w: i32, h: i32) {
        let p = chart::palette(area);
        if self.imp().period_type.borrow().as_str() == "day" {
            let (count, lo, hi, _) = self.hr_stats();
            if count == 0 {
                return;
            }
            let data: Vec<HrPoint> = self
                .imp()
                .heart_samples
                .borrow()
                .iter()
                .map(|s| HrPoint { minute: s.minute, bpm: s.bpm })
                .collect();
            draw_hr_line(cr, w as f64, h as f64, &data, lo as f64, hi as f64, p.error, p.fg);
        } else {
            let data: Vec<BarDatum> = self
                .imp()
                .heart_bars
                .borrow()
                .iter()
                .map(|b| BarDatum {
                    value: b.value as f64,
                    deep: 0.0,
                    has_value: b.has_value,
                    label: b.label.clone(),
                })
                .collect();
            let opts = BarsOpts {
                floor_at_min: true,
                ref_line: 0.0,
                scale: HeightScale::Identity,
                tick: TickFmt::Plain,
                hourly: false,
                bar_color: with_alpha(p.error, 0.4),
                deep_color: p.error,
                ref_color: p.error,
                fg: p.fg,
            };
            draw_metric_bars(cr, w as f64, h as f64, &data, &opts);
        }
    }

    // --- card construction ----------------------------------------------------

    fn build_cards(&self) {
        let content = self.imp().content_box.get();

        // ---- Steps ----
        let (steps_card, steps_headline, steps_unit, steps_typical) =
            section("Steps", "view-statistics-symbolic");
        let steps_area = chart_area(150);
        steps_area.set_draw_func(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |a, cr, w, h| page.draw_steps(a, cr, w, h)
        ));
        steps_card.append(&steps_area);

        let steps_tiles = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        steps_tiles.set_homogeneous(true);
        let (t_dist, tile_distance) = stat_tile("Distance");
        let (t_cal, tile_cal) = stat_tile("Calories");
        let (t_act, tile_active) = stat_tile("Active");
        steps_tiles.append(&t_dist);
        steps_tiles.append(&t_cal);
        steps_tiles.append(&t_act);
        steps_card.append(&steps_tiles);

        let steps_total_label = dim_label();
        steps_card.append(&steps_total_label);
        content.append(&section_root("Steps", &steps_card));

        // ---- Sleep ----
        let (sleep_card, sleep_headline, sleep_unit, sleep_range) =
            section("Sleep", "weather-clear-night-symbolic");
        let sleep_fallback = dim_label();
        sleep_card.append(&sleep_fallback);
        let sleep_empty = dim_label();
        sleep_card.append(&sleep_empty);

        let sleep_timeline_area = chart_area(54);
        sleep_timeline_area.set_draw_func(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |a, cr, w, h| page.draw_sleep_timeline(a, cr, w, h)
        ));
        sleep_card.append(&sleep_timeline_area);

        let sleep_bars_area = chart_area(150);
        sleep_bars_area.set_draw_func(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |a, cr, w, h| page.draw_sleep_bars(a, cr, w, h)
        ));
        sleep_card.append(&sleep_bars_area);

        // legend (deep / light swatch + minutes) + typical.
        let sleep_legend = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        let (deep_entry, sleep_deep_label) = legend_entry(true);
        let (light_entry, sleep_light_label) = legend_entry(false);
        sleep_legend.append(&deep_entry);
        sleep_legend.append(&light_entry);
        let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        spacer.set_hexpand(true);
        sleep_legend.append(&spacer);
        let sleep_typical_legend = dim_label();
        sleep_legend.append(&sleep_typical_legend);
        sleep_card.append(&sleep_legend);

        let sleep_typical_period = dim_label();
        sleep_card.append(&sleep_typical_period);
        content.append(&section_root("Sleep", &sleep_card));

        // ---- Heart rate (no big headline — a stats row instead) ----
        let hr_body = card_body();
        let hr_stats = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        let (hr_resting, hr_resting_val) = hr_stat("Resting");
        let (hr_avg, hr_avg_val) = hr_stat("Average");
        let hr_spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        hr_spacer.set_hexpand(true);
        let (hr_min, hr_min_val) = hr_stat("Min");
        let (hr_max, hr_max_val) = hr_stat("Max");
        hr_stats.append(&hr_resting);
        hr_stats.append(&hr_avg);
        hr_stats.append(&hr_spacer);
        hr_stats.append(&hr_min);
        hr_stats.append(&hr_max);
        hr_body.append(&hr_stats);
        let hr_empty = dim_label();
        hr_body.append(&hr_empty);
        let hr_area = chart_area(150);
        hr_area.set_draw_func(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |a, cr, w, h| page.draw_hr(a, cr, w, h)
        ));
        hr_body.append(&hr_area);
        let hr_card = section_root("Heart rate", &hr_body);
        content.append(&hr_card);

        let cards = Cards {
            steps_headline,
            steps_unit,
            steps_typical,
            steps_area,
            steps_tiles,
            tile_distance,
            tile_cal,
            tile_active,
            steps_total_label,
            sleep_headline,
            sleep_unit,
            sleep_range,
            sleep_fallback,
            sleep_empty,
            sleep_timeline_area,
            sleep_bars_area,
            sleep_legend,
            sleep_deep_label,
            sleep_light_label,
            sleep_typical_legend,
            sleep_typical_period,
            hr_card,
            hr_stats,
            hr_resting,
            hr_resting_val,
            hr_avg,
            hr_avg_val,
            hr_min,
            hr_min_val,
            hr_max,
            hr_max_val,
            hr_empty,
            hr_area,
        };
        self.imp().cards.set(cards).ok();
    }
}

// --- small widget builders ---------------------------------------------------

fn dim_label() -> gtk::Label {
    let l = gtk::Label::builder().xalign(0.0).wrap(true).build();
    l.add_css_class("dim-label");
    l.add_css_class("caption");
    l
}

/// An empty `.card` box (background/border from libadwaita, padding from CSS).
fn card_body() -> gtk::Box {
    let card = gtk::Box::new(gtk::Orientation::Vertical, 12);
    card.add_css_class("card");
    card.add_css_class("section-card");
    card
}

/// A titled section: returns (card body Box, headline Label, unit Label, aux Label).
/// The headline row is `<big number> <unit> ......... <aux>`.
fn section(_title: &str, _icon: &str) -> (gtk::Box, gtk::Label, gtk::Label, gtk::Label) {
    let card = card_body();
    let head = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    let headline = gtk::Label::new(None);
    headline.add_css_class("title-1");
    let unit = gtk::Label::new(None);
    unit.add_css_class("dim-label");
    unit.set_valign(gtk::Align::Baseline);
    let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    let aux = gtk::Label::new(None);
    aux.add_css_class("dim-label");
    aux.add_css_class("caption");
    aux.set_valign(gtk::Align::Baseline);
    head.append(&headline);
    head.append(&unit);
    head.append(&spacer);
    head.append(&aux);
    card.append(&head);
    (card, headline, unit, aux)
}

/// Wrap a card body with a section title above it (returns the outer Box).
fn section_root(title: &str, card: &gtk::Box) -> gtk::Box {
    let outer = gtk::Box::new(gtk::Orientation::Vertical, 6);
    let t = gtk::Label::builder().xalign(0.0).label(title).build();
    t.add_css_class("heading");
    outer.append(&t);
    outer.append(card);
    outer
}

fn chart_area(height: i32) -> gtk::DrawingArea {
    let a = gtk::DrawingArea::new();
    a.set_content_height(height);
    a.set_hexpand(true);
    a
}

fn stat_tile(label: &str) -> (gtk::Box, gtk::Label) {
    let b = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let value = gtk::Label::new(None);
    value.add_css_class("title-4");
    let l = gtk::Label::new(Some(label));
    l.add_css_class("dim-label");
    l.add_css_class("caption");
    b.append(&value);
    b.append(&l);
    (b, value)
}

fn hr_stat(label: &str) -> (gtk::Box, gtk::Label) {
    let b = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 2);
    let value = gtk::Label::new(None);
    value.add_css_class("title-3");
    let bpm = gtk::Label::new(Some("bpm"));
    bpm.add_css_class("dim-label");
    bpm.set_valign(gtk::Align::Baseline);
    row.append(&value);
    row.append(&bpm);
    let l = gtk::Label::new(Some(label));
    l.add_css_class("dim-label");
    l.add_css_class("caption");
    b.append(&row);
    b.append(&l);
    (b, value)
}

/// A sleep legend entry: a themed round swatch + name + minutes label.
fn legend_entry(deep: bool) -> (gtk::Box, gtk::Label) {
    let b = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    let swatch = gtk::DrawingArea::new();
    swatch.set_content_width(12);
    swatch.set_content_height(12);
    swatch.set_valign(gtk::Align::Center);
    swatch.set_draw_func(move |a, cr, w, h| {
        let p = chart::palette(a);
        let c = if deep { chart::darker(p.accent, 1.6) } else { p.accent };
        cr.set_source_rgba(c.red() as f64, c.green() as f64, c.blue() as f64, c.alpha() as f64);
        let r = (w.min(h) as f64) / 2.0;
        cr.arc(w as f64 / 2.0, h as f64 / 2.0, r, 0.0, 2.0 * std::f64::consts::PI);
        let _ = cr.fill();
    });
    let name = gtk::Label::new(Some(if deep { "Deep" } else { "Light" }));
    name.add_css_class("dim-label");
    name.add_css_class("caption");
    let mins = gtk::Label::new(None);
    mins.add_css_class("caption-heading");
    b.append(&swatch);
    b.append(&name);
    b.append(&mins);
    (b, mins)
}

fn set_primary(label: &gtk::Label, primary: bool) {
    label.remove_css_class("title-1");
    label.remove_css_class("title-3");
    label.remove_css_class("error");
    if primary {
        label.add_css_class("title-1");
        label.add_css_class("error");
    } else {
        label.add_css_class("title-3");
    }
}
