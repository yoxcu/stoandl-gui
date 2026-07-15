//! Cairo `draw_func`s for the Health charts — a faithful port of the QML
//! `MetricBars` bar chart, the daily sleep timeline, and the daily HR line.
//!
//! Colours are pulled from the widget's style at draw time (accent/error via the
//! libadwaita named colours, foreground via `Widget::color()`), never hardcoded —
//! so light/dark/accent all track the system theme.

use gtk::cairo;
use gtk::gdk;
use gtk::prelude::*;

const LABEL_H: f64 = 16.0; // reserved strip for x-axis labels

/// Theme colours resolved from a widget at draw time.
pub struct Palette {
    pub accent: gdk::RGBA,
    pub error: gdk::RGBA,
    pub fg: gdk::RGBA,
}

#[allow(deprecated)] // style_context()/lookup_color: no stable replacement for named colours
pub fn palette(w: &impl IsA<gtk::Widget>) -> Palette {
    let ctx = w.style_context();
    let fg = w.color();
    let accent = ctx
        .lookup_color("accent_color")
        .unwrap_or_else(|| gdk::RGBA::new(0.21, 0.52, 0.89, 1.0));
    let error = ctx
        .lookup_color("error_color")
        .unwrap_or_else(|| gdk::RGBA::new(0.88, 0.11, 0.14, 1.0));
    Palette { accent, error, fg }
}

pub fn with_alpha(c: gdk::RGBA, a: f32) -> gdk::RGBA {
    gdk::RGBA::new(c.red(), c.green(), c.blue(), a)
}

/// QML `Qt.darker(c, f)` — divide RGB by the factor (keeps alpha).
pub fn darker(c: gdk::RGBA, f: f32) -> gdk::RGBA {
    gdk::RGBA::new(c.red() / f, c.green() / f, c.blue() / f, c.alpha())
}

fn set(cr: &cairo::Context, c: gdk::RGBA) {
    cr.set_source_rgba(c.red() as f64, c.green() as f64, c.blue() as f64, c.alpha() as f64);
}

fn rounded_rect(cr: &cairo::Context, x: f64, y: f64, w: f64, h: f64, r: f64) {
    if w <= 0.0 || h <= 0.0 {
        return;
    }
    let r = r.min(w / 2.0).min(h / 2.0).max(0.0);
    let deg = std::f64::consts::PI / 180.0;
    cr.new_sub_path();
    cr.arc(x + w - r, y + r, r, -90.0 * deg, 0.0);
    cr.arc(x + w - r, y + h - r, r, 0.0, 90.0 * deg);
    cr.arc(x + r, y + h - r, r, 90.0 * deg, 180.0 * deg);
    cr.arc(x + r, y + r, r, 180.0 * deg, 270.0 * deg);
    cr.close_path();
}

/// Left-baseline text (Cairo toy font — fine for short axis labels).
fn text(cr: &cairo::Context, s: &str, x: f64, y_top: f64, c: gdk::RGBA, size: f64) {
    cr.select_font_face("sans-serif", cairo::FontSlant::Normal, cairo::FontWeight::Normal);
    cr.set_font_size(size);
    set(cr, c);
    // move_to takes a baseline; approximate baseline = top + ~0.8*size.
    let _ = cr.move_to(x, y_top + size * 0.82);
    let _ = cr.show_text(s);
}

fn text_width(cr: &cairo::Context, s: &str, size: f64) -> f64 {
    cr.select_font_face("sans-serif", cairo::FontSlant::Normal, cairo::FontWeight::Normal);
    cr.set_font_size(size);
    cr.text_extents(s).map(|e| e.width()).unwrap_or(0.0)
}

const FONT: f64 = 11.0;

// --- MetricBars --------------------------------------------------------------

#[derive(Clone, Copy)]
pub enum HeightScale {
    Identity,
    MinutesToHours,
}

#[derive(Clone, Copy)]
pub enum TickFmt {
    CompactK,
    Hours,
    Plain,
}

pub struct BarDatum {
    pub value: f64,
    pub deep: f64,
    pub has_value: bool,
    pub label: String,
}

pub struct BarsOpts {
    pub floor_at_min: bool,
    pub ref_line: f64, // value units; 0 = none
    pub scale: HeightScale,
    pub tick: TickFmt,
    pub hourly: bool,
    pub bar_color: gdk::RGBA,
    pub deep_color: gdk::RGBA,
    pub ref_color: gdk::RGBA,
    pub fg: gdk::RGBA,
}

fn scale(s: HeightScale, v: f64) -> f64 {
    match s {
        HeightScale::Identity => v,
        HeightScale::MinutesToHours => v / 60.0,
    }
}

fn nice_ceil(x: f64) -> f64 {
    if x <= 0.0 {
        return 1.0;
    }
    let p = 10f64.powf(x.log10().floor());
    let n = x / p;
    let c = if n <= 1.0 {
        1.0
    } else if n <= 1.2 {
        1.2
    } else if n <= 1.5 {
        1.5
    } else if n <= 2.0 {
        2.0
    } else if n <= 2.5 {
        2.5
    } else if n <= 3.0 {
        3.0
    } else if n <= 4.0 {
        4.0
    } else if n <= 5.0 {
        5.0
    } else if n <= 7.5 {
        7.5
    } else {
        10.0
    };
    c * p
}

fn fmt_tick(f: TickFmt, v: f64) -> String {
    match f {
        TickFmt::CompactK => {
            if v >= 10000.0 {
                format!("{}k", (v / 1000.0).round() as i64)
            } else if v >= 1000.0 {
                format!("{:.1}k", v / 1000.0)
            } else {
                format!("{}", v.round() as i64)
            }
        }
        TickFmt::Hours => format!("{}h", v.round() as i64),
        TickFmt::Plain => format!("{}", v.round() as i64),
    }
}

/// The reusable bar chart (steps / sleep / HR for hourly + week/month).
pub fn draw_metric_bars(cr: &cairo::Context, w: f64, h: f64, data: &[BarDatum], o: &BarsOpts) {
    let n = data.len();
    if n == 0 || w < 20.0 || h < 20.0 {
        return;
    }
    let hv = |v: f64| scale(o.scale, v);

    // floor (series min when floor_at_min, else 0).
    let floor = if o.floor_at_min {
        let mut lo = f64::INFINITY;
        for d in data {
            if d.has_value {
                lo = lo.min(hv(d.value));
            }
        }
        if lo.is_finite() {
            lo
        } else {
            0.0
        }
    } else {
        0.0
    };
    // bar_top.
    let mut m = hv(o.ref_line);
    for d in data {
        if d.has_value {
            m = m.max(hv(d.value));
        }
    }
    let bar_top = if o.floor_at_min {
        (floor + 1.0).max(m)
    } else {
        1f64.max(nice_ceil(m))
    };
    let span = (bar_top - floor).max(1e-6);

    // gutter = widest tick label + pad.
    let ticks: Vec<String> = [0.0f64, 0.5, 1.0]
        .iter()
        .map(|frac| fmt_tick(o.tick, floor + frac * (bar_top - floor)))
        .collect();
    let gutter = ticks
        .iter()
        .map(|t| text_width(cr, t, FONT))
        .fold(0.0, f64::max)
        + 6.0;

    let chart_h = h - LABEL_H;
    let plot_x = gutter;
    let plot_w = w - gutter;
    if plot_w < 4.0 {
        return;
    }
    let y_of = |frac: f64| chart_h - frac * chart_h; // frac 0=bottom .. 1=top

    // gridlines + y-tick labels.
    for (k, frac) in [0.0f64, 0.5, 1.0].iter().enumerate() {
        let y = y_of(*frac);
        set(cr, with_alpha(o.fg, 0.2));
        cr.set_line_width(1.0);
        cr.move_to(plot_x, y.round() + 0.5);
        cr.line_to(w, y.round() + 0.5);
        let _ = cr.stroke();
        // tick label right-aligned in the gutter, clamped inside the chart.
        // `.max(0.0)` keeps clamp's min<=max invariant when a transient resize
        // allocates a height smaller than the label strip (else clamp panics →
        // abort across the Cairo FFI boundary).
        let tw = text_width(cr, &ticks[k], FONT);
        let ty = (y - FONT / 2.0).clamp(0.0, (chart_h - FONT).max(0.0));
        text(cr, &ticks[k], (gutter - 4.0 - tw).max(0.0), ty, with_alpha(o.fg, 0.6), FONT);
    }

    // typical reference line.
    if o.ref_line > 0.0 {
        let frac = (hv(o.ref_line) - floor) / span;
        let y = y_of(frac);
        set(cr, with_alpha(o.ref_color, 0.6));
        cr.set_line_width(1.0);
        cr.move_to(plot_x, y.round() + 0.5);
        cr.line_to(w, y.round() + 0.5);
        let _ = cr.stroke();
    }

    // bars. QML lays them in a RowLayout with an inter-bar gap of
    // max(1, smallSpacing/2) (~3px); subtract it so bar/gap proportions match.
    let gap = 3.0_f64;
    let cell = ((plot_w - (n as f64 - 1.0) * gap) / n as f64).max(2.0);
    for (idx, d) in data.iter().enumerate() {
        let cx = plot_x + (cell + gap) * idx as f64 + cell / 2.0;
        let bw = (cell * 0.7).max(2.0);
        let bx = cx - bw / 2.0;
        let r = (bw / 3.0).min(3.0);
        if d.has_value {
            let frac = ((hv(d.value) - floor) / span).clamp(0.0, 1.0);
            let bh = (frac * chart_h).max(2.0);
            set(cr, o.bar_color);
            rounded_rect(cr, bx, chart_h - bh, bw, bh, r);
            let _ = cr.fill();
        }
        if d.deep > 0.0 {
            let dh = ((hv(d.deep) / span) * chart_h).max(1.0);
            set(cr, o.deep_color);
            rounded_rect(cr, bx, chart_h - dh, bw, dh, r);
            let _ = cr.fill();
        }
    }

    // x-axis labels (hourly ticks, or sparse per-bar).
    let label_every = ((n as f64 / 8.0).ceil() as usize).max(1);
    for (idx, d) in data.iter().enumerate() {
        let s = if o.hourly {
            match idx {
                0 => "12 AM",
                6 => "6 AM",
                12 => "12 PM",
                18 => "6 PM",
                _ => "",
            }
            .to_string()
        } else if idx % label_every == 0 {
            d.label.clone()
        } else {
            String::new()
        };
        if s.is_empty() {
            continue;
        }
        let cx = plot_x + (cell + gap) * idx as f64 + cell / 2.0;
        let tw = text_width(cr, &s, FONT);
        text(cr, &s, cx - tw / 2.0, chart_h + 1.0, with_alpha(o.fg, 0.6), FONT);
    }
}

// --- daily sleep timeline ----------------------------------------------------

pub struct Segment {
    pub start: f64,
    pub width: f64,
    pub deep: bool,
}

/// The night's light/deep timeline across a 6 PM → noon window + a time axis.
pub fn draw_sleep_timeline(
    cr: &cairo::Context,
    w: f64,
    h: f64,
    segs: &[Segment],
    light: gdk::RGBA,
    deep: gdk::RGBA,
    fg: gdk::RGBA,
) {
    if w < 20.0 {
        return;
    }
    let track_h = (h - LABEL_H - 4.0).clamp(8.0, 28.0);
    let r = track_h / 5.0;

    // track background (fg at low alpha).
    set(cr, with_alpha(fg, 0.07));
    rounded_rect(cr, 0.0, 0.0, w, track_h, r);
    let _ = cr.fill();

    for s in segs {
        let x = s.start * w;
        let sw = (s.width * w).max(2.0);
        set(cr, if s.deep { deep } else { light });
        rounded_rect(cr, x, 0.0, sw, track_h, r);
        let _ = cr.fill();
    }

    // axis labels.
    for (label, frac) in [("6 PM", 0.0), ("12 AM", 0.3333), ("6 AM", 0.6667), ("noon", 1.0)] {
        let tw = text_width(cr, label, FONT);
        let x = (frac * w - tw / 2.0).clamp(0.0, w - tw);
        text(cr, label, x, track_h + 4.0, with_alpha(fg, 0.5), FONT);
    }
}

// --- daily heart-rate line ---------------------------------------------------

pub struct HrPoint {
    pub minute: i32,
    pub bpm: i32,
}

/// Minute-level HR line with a filled area, a left bpm y-axis, and a time axis.
pub fn draw_hr_line(
    cr: &cairo::Context,
    w: f64,
    h: f64,
    data: &[HrPoint],
    lo: f64,
    hi: f64,
    line: gdk::RGBA,
    fg: gdk::RGBA,
) {
    if data.is_empty() || w < 20.0 || h < 20.0 {
        return;
    }
    let gutter = {
        let mx = text_width(cr, &format!("{}", hi.round() as i64), FONT)
            .max(text_width(cr, &format!("{}", lo.round() as i64), FONT));
        mx + 6.0
    };
    let plot_x = gutter;
    let plot_w = w - gutter;
    let plot_h = h - LABEL_H;
    let pad = 3.0;
    let span = (hi - lo).max(1.0);
    if plot_w < 4.0 {
        return;
    }
    let y_of = |frac: f64| plot_h - frac * (plot_h - 2.0 * pad) - pad;
    let px = |min: f64| plot_x + (min / 1440.0) * plot_w;
    let py = |v: f64| y_of((v - lo) / span);

    // gridlines + bpm ticks (min / mid / max).
    for frac in [0.0f64, 0.5, 1.0] {
        let y = y_of(frac);
        set(cr, with_alpha(fg, 0.2));
        cr.set_line_width(1.0);
        cr.move_to(plot_x, y.round() + 0.5);
        cr.line_to(w, y.round() + 0.5);
        let _ = cr.stroke();
        let val = (lo + frac * (hi - lo)).round() as i64;
        let s = format!("{val}");
        let tw = text_width(cr, &s, FONT);
        let ty = (y - FONT / 2.0).clamp(0.0, (plot_h - FONT).max(0.0));
        text(cr, &s, (gutter - 4.0 - tw).max(0.0), ty, with_alpha(fg, 0.6), FONT);
    }

    if data.len() == 1 {
        let d = &data[0];
        set(cr, line);
        cr.arc(px(d.minute as f64), py(d.bpm as f64), 3.0, 0.0, 2.0 * std::f64::consts::PI);
        let _ = cr.fill();
    } else {
        // filled area under the line.
        cr.move_to(px(data[0].minute as f64), py(data[0].bpm as f64));
        for d in &data[1..] {
            cr.line_to(px(d.minute as f64), py(d.bpm as f64));
        }
        let last_x = px(data[data.len() - 1].minute as f64);
        let first_x = px(data[0].minute as f64);
        cr.line_to(last_x, plot_h);
        cr.line_to(first_x, plot_h);
        cr.close_path();
        let grad = cairo::LinearGradient::new(0.0, 0.0, 0.0, plot_h);
        grad.add_color_stop_rgba(
            0.0,
            line.red() as f64,
            line.green() as f64,
            line.blue() as f64,
            0.35,
        );
        grad.add_color_stop_rgba(
            1.0,
            line.red() as f64,
            line.green() as f64,
            line.blue() as f64,
            0.0,
        );
        let _ = cr.set_source(&grad);
        let _ = cr.fill();

        // the line itself.
        cr.move_to(px(data[0].minute as f64), py(data[0].bpm as f64));
        for d in &data[1..] {
            cr.line_to(px(d.minute as f64), py(d.bpm as f64));
        }
        set(cr, line);
        cr.set_line_width(2.0);
        cr.set_line_join(cairo::LineJoin::Round);
        let _ = cr.stroke();
    }

    // time axis.
    for (label, frac) in [("12 AM", 0.0), ("6 AM", 0.25), ("12 PM", 0.5), ("6 PM", 0.75), ("12 AM", 1.0)] {
        let tw = text_width(cr, label, FONT);
        let x = (plot_x + frac * plot_w - tw / 2.0).clamp(plot_x, w - tw);
        text(cr, label, x, plot_h + 1.0, with_alpha(fg, 0.5), FONT);
    }
}
