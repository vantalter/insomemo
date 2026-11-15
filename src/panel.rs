//! Chooses the tray icon's ink for hosts that draw the icon file without
//! recolouring it (see `tray_svg`). Cinnamon's panel colours come from its
//! theme's stylesheet; elsewhere the desktop's light/dark preference stands in.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]
use crate::tray_svg::Ink;
use std::path::{Path, PathBuf};

/// Cinnamon's built-in theme, used when no theme is selected.
const CINNAMON_DEFAULT: &str = "/usr/share/cinnamon/theme/cinnamon.css";

/// `cinnamon_theme` is Cinnamon's theme name, `None` outside Cinnamon and
/// empty for its built-in theme. `color_scheme` is the XDG portal's
/// `org.freedesktop.appearance` value: 1 prefers dark, 2 light.
pub fn ink(cinnamon_theme: Option<&str>, color_scheme: u32) -> Ink {
    if let Some(theme) = cinnamon_theme {
        // Linux Mint's default pairs light windows with a dark panel, so the
        // preference says nothing about Cinnamon's panel.
        return stylesheet(theme, &theme_dirs())
            .and_then(|css| panel_ink(&css))
            .unwrap_or(Ink::Light);
    }
    // GNOME's top bar stays dark whatever the preference.
    let gnome = std::env::var("XDG_CURRENT_DESKTOP")
        .is_ok_and(|desktop| desktop.split(':').any(|d| d == "GNOME"));
    if color_scheme == 2 && !gnome {
        Ink::Dark
    } else {
        Ink::Light
    }
}

/// Where Cinnamon looks for themes, in its order of preference.
fn theme_dirs() -> Vec<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let data_home = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| home.as_ref().map(|h| h.join(".local/share")));
    let data_dirs = std::env::var("XDG_DATA_DIRS")
        .ok()
        .filter(|dirs| !dirs.is_empty())
        .unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    home.map(|h| h.join(".themes"))
        .into_iter()
        .chain(data_home.map(|d| d.join("themes")))
        .chain(data_dirs.split(':').map(|d| Path::new(d).join("themes")))
        .collect()
}

fn stylesheet(theme: &str, dirs: &[PathBuf]) -> Option<String> {
    if theme.is_empty() || theme == "cinnamon" {
        return std::fs::read_to_string(CINNAMON_DEFAULT).ok();
    }
    // A theme name, never a path.
    if theme.contains('/') || theme.starts_with('.') {
        return None;
    }
    dirs.iter()
        .find_map(|dir| std::fs::read_to_string(dir.join(theme).join("cinnamon/cinnamon.css")).ok())
}

/// The panel's text colour sets the ink of symbolic icons in Cinnamon, so it
/// decides when a theme sets one; otherwise the ink contrasts with the panel's
/// background.
fn panel_ink(css: &str) -> Option<Ink> {
    let ink = |light| if light { Ink::Light } else { Ink::Dark };
    panel_property(css, "color")
        .map(|text| ink(is_light(text)))
        .or_else(|| panel_property(css, "background-color").map(|bg| ink(!is_light(bg))))
}

/// The first colour set for `property` by a rule styling the panel itself.
fn panel_property(css: &str, property: &str) -> Option<[u8; 3]> {
    let css = without_comments(css);
    css.split('}').find_map(|rule| {
        let (selectors, body) = rule.rsplit_once('{')?;
        let panel = selectors.split(',').any(|selector| {
            matches!(
                selector.trim(),
                "#panel" | ".panel-top" | ".panel-bottom" | ".panel-left" | ".panel-right"
            )
        });
        if !panel {
            return None;
        }
        body.split(';').find_map(|declaration| {
            let (name, value) = declaration.split_once(':')?;
            (name.trim() == property).then(|| colour(value)).flatten()
        })
    })
}

fn without_comments(css: &str) -> String {
    let mut result = String::with_capacity(css.len());
    let mut rest = css;
    while let Some(start) = rest.find("/*") {
        result.push_str(&rest[..start]);
        rest = rest[start..]
            .find("*/")
            .map_or("", |end| &rest[start + end + 2..]);
    }
    result.push_str(rest);
    result
}

/// `#rgb`, `#rrggbb` (with or without alpha), `rgb()`, and `rgba()`.
fn colour(value: &str) -> Option<[u8; 3]> {
    let value = value.trim().trim_end_matches("!important").trim();
    if let Some(hex) = value.strip_prefix('#') {
        let digits: Vec<u8> = hex
            .chars()
            .map(|c| c.to_digit(16).map(|d| d as u8))
            .collect::<Option<_>>()?;
        return match digits.len() {
            3 | 4 => Some([digits[0] * 17, digits[1] * 17, digits[2] * 17]),
            6 | 8 => Some([
                digits[0] * 16 + digits[1],
                digits[2] * 16 + digits[3],
                digits[4] * 16 + digits[5],
            ]),
            _ => None,
        };
    }
    let inner = value
        .strip_prefix("rgba(")
        .or_else(|| value.strip_prefix("rgb("))?
        .strip_suffix(')')?;
    let mut channels = inner.split(',').map(|c| c.trim().parse::<u8>().ok());
    Some([channels.next()??, channels.next()??, channels.next()??])
}

/// Perceived brightness above the midpoint.
fn is_light([r, g, b]: [u8; 3]) -> bool {
    299 * r as u32 + 587 * g as u32 + 114 * b as u32 > 127_500
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn panel_text_colour_decides_the_ink() {
        // Mint-Y and Mint-Y-Dark: the comment and nesting are as shipped.
        let mint_y = "#panel {\n  font-weight: bold;\n  /* Set the symbolic foreground color for icons */\n  color: #303030; }\n  #panelLeft {\n    spacing: 4px; }\n.panel-top, .panel-bottom, .panel-left, .panel-right {\n  background-color: rgba(243, 243, 244, 0.99); }";
        assert_eq!(panel_ink(mint_y), Some(Ink::Dark));
        assert_eq!(
            panel_ink(&mint_y.replace("#303030", "#e1e1e1")),
            Some(Ink::Light)
        );
        // Without a text colour, the ink contrasts with the background.
        let builtin = ".panel-top, .panel-bottom { font-weight: bold; background-color: rgba(29, 29, 33, 0.99); }";
        assert_eq!(panel_ink(builtin), Some(Ink::Light));
        // Hover and edit-mode rules are not the panel itself.
        assert_eq!(
            panel_ink("#panel:highlight { background-color: #fff; }"),
            None
        );
    }

    #[test]
    fn colours_parse_in_css_notations() {
        assert_eq!(colour(" #FfF "), Some([255, 255, 255]));
        assert_eq!(colour("#30303080"), Some([48, 48, 48]));
        assert_eq!(colour("rgb(1, 2, 3) !important"), Some([1, 2, 3]));
        assert_eq!(colour("transparent"), None);
        assert_eq!(colour("#12345"), None);
        assert!(is_light([243, 243, 244]) && !is_light([29, 29, 33]));
    }

    #[test]
    fn themes_resolve_by_name_only() {
        let dir = std::env::temp_dir().join(format!("insomemo-themes-{}", std::process::id()));
        let css = dir.join("Mint-Y/cinnamon/cinnamon.css");
        std::fs::create_dir_all(css.parent().unwrap()).unwrap();
        std::fs::write(&css, "#panel { color: #303030; }").unwrap();
        let dirs = [PathBuf::from("/nonexistent"), dir.clone()];
        assert!(stylesheet("Mint-Y", &dirs).is_some());
        assert!(stylesheet("Missing", &dirs).is_none());
        assert!(stylesheet("../Mint-Y", &dirs).is_none());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn outside_cinnamon_only_an_explicit_light_preference_darkens_the_ink() {
        if std::env::var("XDG_CURRENT_DESKTOP").is_ok_and(|d| d.contains("GNOME")) {
            return;
        }
        assert_eq!(ink(None, 2), Ink::Dark);
        assert_eq!(ink(None, 1), Ink::Light);
        assert_eq!(ink(None, 0), Ink::Light);
    }
}
