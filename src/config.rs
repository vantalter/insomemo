use serde::{Deserialize, Serialize};
use std::{fs, path::Path};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub title_tracking_apps: Vec<String>,
    /// Exact suffixes removed before hashing; no fuzzy matching of conversations.
    pub title_suffixes: Vec<String>,
    pub default_layout: Option<String>,
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
        let joined = title.split_whitespace().collect::<Vec<_>>().join(" ");
        let mut clean = strip_unread_badge(&joined).to_owned();
        for suffix in &self.title_suffixes {
            if let Some(prefix) = clean.strip_suffix(suffix) {
                clean = prefix.trim_end().to_owned();
            }
        }
        clean
    }
}

/// Unread counts such as "(3) Inbox" or "[12+] Chat" would make every new
/// message a new context; strip one leading badge.
fn strip_unread_badge(title: &str) -> &str {
    for (open, close) in [('(', ')'), ('[', ']')] {
        if let Some(rest) = title.strip_prefix(open)
            && let Some((count, rest)) = rest.split_once(close)
            && let Some(rest) = rest.strip_prefix(' ')
        {
            let digits = count.strip_suffix('+').unwrap_or(count);
            if !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit()) {
                return rest;
            }
        }
    }
    title
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unread_badges_do_not_change_the_context() {
        let config = Config::default();
        assert_eq!(config.clean_title("(3) Inbox - Gmail"), "Inbox - Gmail");
        assert_eq!(config.clean_title("[12+]  general"), "general");
        assert_eq!(config.clean_title("Inbox - Gmail"), "Inbox - Gmail");
        assert_eq!(config.clean_title("(draft) notes"), "(draft) notes");
        assert_eq!(config.clean_title("(2024) report"), "report");
        assert_eq!(config.clean_title("(+) add"), "(+) add");
    }
}
