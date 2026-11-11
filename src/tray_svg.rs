//! Linux tray icons as symbolic SVGs, drawn from the same geometry as the
//! macOS template (`scripts/generate-tray-keyboard.m`, a 72-unit canvas).
//! Tray hosts recolour "-symbolic" icons to the panel's text colour: GTK by
//! overriding fills, KDE through the `ColorScheme-Text` class. Every shape is
//! therefore a plain fill; holes come from even-odd paths and clip paths.
//! Hosts that draw the file as is, such as Cinnamon and Enlightenment, use the
//! stylesheet's colour, so each icon comes in a light and a dark ink; `panel`
//! chooses between them.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]
use crate::engine::IndicatorPosition;
use std::path::{Path, PathBuf};

const CANVAS: f64 = 72.0;
/// Badge size relative to the icon, as on macOS.
const DOT: f64 = CANVAS * 0.36;
const GAP: f64 = CANVAS * 0.08;

/// Colour for hosts that do not recolour the icon: light for dark panels,
/// the default, or dark for light ones.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ink {
    Light,
    Dark,
}

impl Ink {
    /// Breeze's text colours on dark and on light backgrounds.
    fn colour(self) -> &'static str {
        match self {
            Ink::Light => "eff0f1",
            Ink::Dark => "232629",
        }
    }
}

const BADGES: [Option<IndicatorPosition>; 3] = [
    None,
    Some(IndicatorPosition::TopRight),
    Some(IndicatorPosition::BottomRight),
];

/// `insomemo[-dark][-<corner>]-symbolic`; `icon_name` in native/linux.c builds
/// the same names.
pub fn name(ink: Ink, badge: Option<IndicatorPosition>) -> String {
    let ink = if ink == Ink::Dark { "-dark" } else { "" };
    let badge = badge.map_or(String::new(), |position| format!("-{}", position.id()));
    format!("insomemo{ink}{badge}-symbolic")
}

/// Two decimals keep the SVG readable, e.g. 25.92 rather than 25.919999999999998.
fn n(value: f64) -> String {
    format!("{}", (value * 100.0).round() / 100.0)
}

fn rounded(x: f64, y: f64, w: f64, h: f64, r: f64) -> String {
    let (start, top, iw, ih, r) = (n(x + r), n(y), n(w - 2.0 * r), n(h - 2.0 * r), n(r));
    format!(
        "M{start} {top}h{iw}a{r} {r} 0 0 1 {r} {r}v{ih}a{r} {r} 0 0 1 -{r} {r}h-{iw}a{r} {r} 0 0 1 -{r} -{r}v-{ih}a{r} {r} 0 0 1 {r} -{r}z"
    )
}

fn circle(cx: f64, cy: f64, r: f64) -> String {
    let (left, cy, d, r) = (n(cx - r), n(cy), n(2.0 * r), n(r));
    format!("M{left} {cy}a{r} {r} 0 1 0 {d} 0a{r} {r} 0 1 0 -{d} 0z")
}

/// A 5-unit stroke centred on the rectangle, as a filled ring.
fn outline(x: f64, y: f64, w: f64, h: f64, r: f64) -> String {
    rounded(x - 2.5, y - 2.5, w + 5.0, h + 5.0, r + 2.5)
        + &rounded(x + 2.5, y + 2.5, w - 5.0, h - 5.0, r - 2.5)
}

pub fn svg(badge: Option<IndicatorPosition>, ink: Ink) -> String {
    let canvas = rounded(0.0, 0.0, CANVAS, CANVAS, 0.0);
    let front = rounded(7.0, 23.0, 50.0, 42.0, 8.0);
    let mut holes = String::new();
    for i in 0..4 {
        holes += &rounded(15.5 + 9.0 * i as f64, 34.5, 6.0, 6.0, 2.2);
    }
    for i in 0..5 {
        holes += &rounded(11.5 + 9.0 * i as f64, 44.5, 6.0, 6.0, 2.2);
    }
    holes += &rounded(20.0, 54.5, 24.0, 5.5, 2.75);
    // Separate paths: within one even-odd path, the overlapping rings would cancel.
    let (back, middle) = (
        outline(25.0, 8.0, 40.0, 42.0, 8.0),
        outline(18.0, 16.0, 41.0, 42.0, 8.0),
    );
    let paint = r#"class="ColorScheme-Text" fill="currentColor" fill-rule="evenodd""#;
    // The back cards show only around the front card, never through its holes.
    let mut defs = format!(
        r#"<clipPath id="behind"><path clip-rule="evenodd" d="{canvas}{front}"/></clipPath>"#
    );
    let mut body = format!(
        r#"<g clip-path="url(#behind)"><path {paint} d="{back}"/><path {paint} d="{middle}"/></g><path {paint} d="{front}{holes}"/>"#
    );
    if let Some(position) = badge {
        let cx = CANVAS - DOT / 2.0;
        let cy = match position {
            IndicatorPosition::TopRight => DOT / 2.0,
            IndicatorPosition::BottomRight => CANVAS - DOT / 2.0,
        };
        // A transparent ring separates the dot from the cards, as on macOS.
        let ring = circle(cx, cy, DOT / 2.0 + GAP);
        defs += &format!(
            r#"<clipPath id="ring"><path clip-rule="evenodd" d="{canvas}{ring}"/></clipPath>"#
        );
        body = format!(
            r#"<g clip-path="url(#ring)">{body}</g><path {paint} d="{}"/>"#,
            circle(cx, cy, DOT / 2.0)
        );
    }
    format!(
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="72" height="72" viewBox="0 0 72 72"><style id="current-color-scheme">.ColorScheme-Text{{color:#{}}}</style><defs>{defs}</defs>{body}</svg>
"#,
        ink.colour()
    )
}

const INDEX: &str = "[Icon Theme]\nName=Hicolor\nDirectories=scalable/apps\n\n[scalable/apps]\nSize=16\nMinSize=8\nMaxSize=512\nType=Scalable\n";

/// Writes the icons where the tray host can load them and returns the
/// directory to advertise as the StatusNotifierItem's IconThemePath.
pub fn install() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")))?;
    let dir = base.join("insomemo").join("icons");
    match write_icons(&dir) {
        Ok(()) => Some(dir),
        Err(e) => {
            eprintln!(
                "insomemo: cannot write tray icons to {}: {e}",
                dir.display()
            );
            None
        }
    }
}

/// Hosts differ in how they search IconThemePath, so each icon is written both
/// directly in it (GTK) and inside a hicolor theme (KDE).
fn write_icons(dir: &Path) -> std::io::Result<()> {
    let themed = dir.join("hicolor").join("scalable").join("apps");
    std::fs::create_dir_all(&themed)?;
    std::fs::write(dir.join("hicolor").join("index.theme"), INDEX)?;
    for ink in [Ink::Light, Ink::Dark] {
        for badge in BADGES {
            let (name, contents) = (name(ink, badge), svg(badge, ink));
            std::fs::write(dir.join(format!("{name}.svg")), &contents)?;
            std::fs::write(themed.join(format!("{name}.svg")), &contents)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn icons_are_well_formed_and_only_badges_have_a_dot() {
        let plain = svg(None, Ink::Light);
        let badged = svg(Some(IndicatorPosition::BottomRight), Ink::Light);
        for icon in [&plain, &badged] {
            assert!(icon.starts_with("<svg ") && icon.trim_end().ends_with("</svg>"));
            assert_eq!(icon.matches("<path").count(), icon.matches("/>").count());
        }
        assert!(!plain.contains("id=\"ring\""));
        assert!(badged.contains("id=\"ring\""));
        // The bottom-right dot sits at y = 72 - 12.96.
        assert!(badged.contains(" 59.04a12.96"));
        assert_ne!(svg(Some(IndicatorPosition::TopRight), Ink::Light), badged);
    }

    #[test]
    fn inks_differ_only_in_the_colour_hosts_fall_back_to() {
        let light = svg(None, Ink::Light);
        let dark = svg(None, Ink::Dark);
        assert!(light.contains(".ColorScheme-Text{color:#eff0f1}"));
        assert_eq!(light.replace("eff0f1", "232629"), dark);
        assert_eq!(name(Ink::Light, None), "insomemo-symbolic");
        assert_eq!(
            name(Ink::Dark, Some(IndicatorPosition::TopRight)),
            "insomemo-dark-top-right-symbolic"
        );
    }

    #[test]
    fn icons_are_written_flat_and_themed() {
        let dir = std::env::temp_dir().join(format!("insomemo-icons-{}", std::process::id()));
        write_icons(&dir).unwrap();
        assert!(dir.join("insomemo-symbolic.svg").exists());
        assert!(dir.join("insomemo-dark-bottom-right-symbolic.svg").exists());
        assert!(
            dir.join("hicolor/scalable/apps/insomemo-bottom-right-symbolic.svg")
                .exists()
        );
        assert!(dir.join("hicolor/index.theme").exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
