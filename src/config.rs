use serde::{Deserialize, Serialize};
use std::{fs, path::Path};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub title_tracking_apps: Vec<String>,
    /// Exact suffixes removed before hashing; no fuzzy matching of conversations.
    pub title_suffixes: Vec<String>,
    pub default_layout: Option<String>,
    /// macOS only: explicit address-field input source; None chooses installed English.
    pub browser_address_bar_layout: Option<String>,
    /// Subset of supported macOS browser bundle IDs eligible for the override.
    pub browser_address_bar_apps: Vec<String>,
    /// Wayland keyboard identifier/name. None selects the first/main keyboard.
    pub keyboard: Option<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            title_tracking_apps: [
                "com.mitchellh.ghostty",
                "com.googlecode.iterm2",
                "com.apple.Terminal",
                "com.tinyspeck.slackmacgap",
                "com.viber.osx",
                "com.hnc.Discord",
                "com.google.Chrome",
                "org.mozilla.firefox",
                "com.apple.Safari",
                "ghostty",
                "Alacritty",
                "kitty",
                "Slack",
                "discord",
                "Viber",
                "firefox",
                "Google-chrome",
            ]
            .iter()
            .map(|s| (*s).into())
            .collect(),
            title_suffixes: Vec::new(),
            default_layout: None,
            browser_address_bar_layout: None,
            browser_address_bar_apps: [
                "com.google.Chrome",
                "com.apple.Safari",
                "org.mozilla.firefox",
            ]
            .iter()
            .map(|s| (*s).into())
            .collect(),
            keyboard: None,
        }
    }
}

impl Config {
    pub fn load(path: &Path) -> Result<Self, String> {
        match fs::read_to_string(path) {
            Ok(contents) => {
                serde_json::from_str(&contents).map_err(|e| format!("{}: {e}", path.display()))
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(e) => Err(format!("{}: {e}", path.display())),
        }
    }

    pub fn clean_title(&self, title: &str) -> String {
        let mut clean = title.split_whitespace().collect::<Vec<_>>().join(" ");
        for suffix in &self.title_suffixes {
            if let Some(prefix) = clean.strip_suffix(suffix) {
                clean = prefix.trim_end().to_owned();
            }
        }
        clean
    }
}
