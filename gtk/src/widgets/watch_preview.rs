//! A mock-up of the watch's notification card, so the Alerts page and the per-app dialog show where
//! `notification.app_name` puts an app's name while an option is picked.
//!
//! PebbleOS draws the card top to bottom: a banner in the app's colour with its icon, the Title (bold),
//! the Subtitle (the largest bold font), the small line (LocationName), the Body and a relative time —
//! black on white in either theme, as the card here is (`.watch-card` in style.css). The text uses the
//! system font at the relative sizes and weights of the watch's Gothic fonts.

use std::cell::Cell;
use std::rc::Rc;

use adw::prelude::*;
use gtk::{glib, pango};

/// The sample notification every preview shows.
const TITLE: &str = "Family";
const BODY: &str = "Alice: are we still on for tonight?";
const TIME: &str = "now";

/// The watch's colour for an app without one of its own: "Folly", #FF0055.
const FOLLY: (f64, f64, f64) = (1.0, 0.0, 0.333);

/// The line the app name takes, as `(slot, name)`. Mirrors the daemon's `watchFields`
/// (NotificationLayout.kt) for a notification without a subtitle of its own: `subtitle` puts the name
/// in the Subtitle (the largest bold font), `small` on the small line (LocationName), and anything else
/// (`off`) leaves it off the card — as does a name that repeats the title. The only copy of that rule
/// in this front-end.
pub fn app_name_line(app_name: &str, title: &str, placement: &'static str) -> Option<(&'static str, String)> {
    let name = app_name.trim();
    let shown = matches!(placement, "subtitle" | "small")
        && !name.is_empty()
        && name.to_lowercase() != title.trim().to_lowercase();
    shown.then(|| (placement, name.to_string()))
}

/// The card. Cheap to clone (widget refs + shared state); add [`WatchPreview::widget`] to a container.
#[derive(Clone)]
pub struct WatchPreview {
    root: adw::Clamp,
    card: gtk::Box,
    banner: gtk::DrawingArea,
    icon: gtk::Image,
    subtitle: gtk::Label,
    small: gtk::Label,
    app_name: Rc<str>,
    placement: Rc<Cell<&'static str>>,
    rgb: Rc<Cell<(f64, f64, f64)>>,
}

impl WatchPreview {
    /// A card for `app_name`, on the small line and the default colour until told otherwise.
    pub fn new(app_name: &str) -> Self {
        let rgb = Rc::new(Cell::new(FOLLY));
        let banner = gtk::DrawingArea::builder().hexpand(true).css_classes(["watch-banner"]).build();
        banner.set_draw_func(glib::clone!(
            #[strong]
            rgb,
            move |_, cr, w, h| {
                let (r, g, b) = rgb.get();
                cr.set_source_rgb(r, g, b);
                cr.rectangle(0.0, 0.0, w as f64, h as f64);
                let _ = cr.fill();
            }
        ));
        let icon = gtk::Image::builder()
            .icon_name("preferences-system-notifications-symbolic")
            .halign(gtk::Align::Center)
            .valign(gtk::Align::Center)
            .css_classes(["watch-banner-icon"])
            .build();
        let header = gtk::Overlay::builder().child(&banner).build();
        header.add_overlay(&icon);

        let line = |class: &str, text: &str| {
            gtk::Label::builder()
                .label(text)
                .xalign(0.0)
                .wrap(true)
                .wrap_mode(pango::WrapMode::WordChar)
                .css_classes([class])
                .build()
        };
        let title = line("watch-title", TITLE);
        let subtitle = line("watch-subtitle", "");
        let small = line("watch-small", "");
        let body = line("watch-body", BODY);
        body.set_lines(3); // the watch scrolls a longer body; the preview just cuts it
        body.set_ellipsize(pango::EllipsizeMode::End);
        let time = line("watch-time", TIME);
        let text = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .css_classes(["watch-text"])
            .build();
        for l in [&title, &subtitle, &small, &body, &time] {
            text.append(l);
        }

        let card = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .overflow(gtk::Overflow::Hidden) // clip the banner to the rounded corners
            .accessible_role(gtk::AccessibleRole::Img)
            .css_classes(["watch-card"])
            .build();
        card.append(&header);
        card.append(&text);
        // Assistive tech reads the card's own name and description (see render); hide the parts so the
        // lines aren't read twice.
        header.update_state(&[gtk::accessible::State::Hidden(true)]);
        text.update_state(&[gtk::accessible::State::Hidden(true)]);

        // The 200 × 228 screen of a Time 2, in sp so it grows with the text scale: the clamp sets the
        // width, the card's height request the height.
        let height = adw::LengthUnit::Sp.to_px(228.0, gtk::Settings::default().as_ref());
        card.set_size_request(-1, height.round() as i32);
        let root = adw::Clamp::builder()
            .maximum_size(200)
            .tightening_threshold(200)
            .unit(adw::LengthUnit::Sp)
            .margin_top(12)
            .child(&card)
            .build();

        let preview = Self {
            root,
            card,
            banner,
            icon,
            subtitle,
            small,
            app_name: Rc::from(app_name),
            placement: Rc::new(Cell::new("small")),
            rgb,
        };
        preview.render();
        preview
    }

    pub fn widget(&self) -> &adw::Clamp {
        &self.root
    }

    /// Where the app name goes: `small`, `subtitle` or `off` (a per-app Default resolved by the caller).
    pub fn set_placement(&self, placement: &'static str) {
        self.placement.set(placement);
        self.render();
    }

    pub fn placement(&self) -> &'static str {
        self.placement.get()
    }

    /// The banner colour as RGB; `None` is the watch's default.
    pub fn set_color(&self, rgb: Option<(f64, f64, f64)>) {
        self.rgb.set(rgb.unwrap_or(FOLLY));
        self.render();
    }

    /// The card's lines top to bottom, as `(slot, text)`: `title`, the app name's `subtitle` or `small`
    /// when it is on the card, `body`, `time`.
    pub fn lines(&self) -> Vec<(&'static str, String)> {
        let mut lines = vec![("title", TITLE.to_string())];
        lines.extend(app_name_line(&self.app_name, TITLE, self.placement.get()));
        lines.push(("body", BODY.to_string()));
        lines.push(("time", TIME.to_string()));
        lines
    }

    /// The lines as the smoke harness logs them: `title=Family | small=NeoChat | …`.
    pub fn summary(&self) -> String {
        self.lines().iter().map(|(slot, text)| format!("{slot}={text}")).collect::<Vec<_>>().join(" | ")
    }

    fn render(&self) {
        let lines = self.lines();
        let text = |slot: &str| lines.iter().find(|(s, _)| *s == slot).map(|(_, t)| t.as_str());
        for (label, slot) in [(&self.subtitle, "subtitle"), (&self.small, "small")] {
            label.set_visible(text(slot).is_some());
            label.set_text(text(slot).unwrap_or_default());
        }
        let texts: Vec<&str> = lines.iter().map(|(_, t)| t.as_str()).collect();
        let place = if text("subtitle").is_some() {
            "The app name is the subtitle"
        } else if text("small").is_some() {
            "The app name is a small line under the title"
        } else {
            "The app name is not on the card"
        };
        self.card.update_property(&[
            gtk::accessible::Property::Label(&format!("Watch preview: {}", texts.join(", "))),
            gtk::accessible::Property::Description(place),
        ]);
        // A black icon on the light banners (yellow, green, cyan), white on the rest, so it stays visible.
        let (r, g, b) = self.rgb.get();
        if 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.6 {
            self.icon.add_css_class("on-light");
        } else {
            self.icon.remove_css_class("on-light");
        }
        self.banner.queue_draw();
    }
}

#[cfg(test)]
mod tests {
    use super::app_name_line;

    #[test]
    fn app_name_goes_where_the_placement_says() {
        let on = |slot, name: &str| Some((slot, name.to_string()));
        assert_eq!(app_name_line("NeoChat", "Family", "small"), on("small", "NeoChat"));
        assert_eq!(app_name_line("NeoChat", "Family", "subtitle"), on("subtitle", "NeoChat"));
        assert_eq!(app_name_line("NeoChat", "Family", "off"), None);
        // Never a line that repeats the title (case and padding aside), nor an empty one.
        assert_eq!(app_name_line(" family ", "Family", "subtitle"), None);
        assert_eq!(app_name_line("  ", "Family", "small"), None);
        assert_eq!(app_name_line(" NeoChat ", "Family", "small"), on("small", "NeoChat"));
    }
}
