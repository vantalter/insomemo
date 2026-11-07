use crate::config::Config;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const CAPACITY: usize = 200;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Entry {
    pub layout: String,
    pub used: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct State {
    pub version: u32,
    pub entries: BTreeMap<String, Entry>,
    #[serde(default)]
    pub default_layout: Option<String>,
    #[serde(default = "enabled_by_default")]
    pub browser_address_bar_enabled: bool,
}

fn enabled_by_default() -> bool {
    true
}

impl Default for State {
    fn default() -> Self {
        Self {
            version: 1,
            entries: BTreeMap::new(),
            default_layout: None,
            browser_address_bar_enabled: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Context {
    pub app: String,
    pub title: String,
    pub key: String,
    pub window_id: String,
    pub address_bar: bool,
}

pub struct Engine {
    pub config: Config,
    pub state: State,
    pub active: Option<Context>,
    pub current_layout: String,
    pub paused: bool,
    pub dirty: bool,
    pending: Option<String>,
    address_bar_previous_layout: Option<String>,
    address_bar_layout: Option<String>,
    clock: u64,
}

impl Engine {
    pub fn new(config: Config, mut state: State) -> Self {
        let address_bar_layout = config.browser_address_bar_layout.clone();
        // Rebase persisted counters, including malicious/overflowing values.
        let mut order: Vec<_> = state
            .entries
            .iter()
            .map(|(k, v)| (k.clone(), v.used))
            .collect();
        order.sort_by_key(|(_, used)| *used);
        for (i, (key, _)) in order.iter().enumerate() {
            state.entries.get_mut(key).unwrap().used = i as u64 + 1;
        }
        let clock = order.len() as u64;
        let mut engine = Self {
            config,
            state,
            active: None,
            current_layout: String::new(),
            paused: false,
            dirty: false,
            pending: None,
            address_bar_previous_layout: None,
            address_bar_layout,
            clock,
        };
        engine.prune();
        engine
    }

    pub fn focus(&mut self, app: &str, title: &str) -> Option<String> {
        self.focus_window(app, title, "")
    }

    pub fn focus_window(&mut self, app: &str, title: &str, window_id: &str) -> Option<String> {
        self.focus_context(app, title, window_id, false)
    }

    pub fn focus_context(
        &mut self,
        app: &str,
        title: &str,
        window_id: &str,
        address_bar: bool,
    ) -> Option<String> {
        if app.is_empty() {
            self.active = None;
            self.pending = None;
            self.address_bar_previous_layout = None;
            return None;
        }
        let title = self.config.clean_title(title);
        let track = self.config.title_tracking_apps.iter().any(|a| a == app);
        let key = if track && !window_id.is_empty() {
            format!(
                "{app}:{}",
                crate::native::title_hash(&format!("window:{window_id}"))
            )
        } else if track && !title.is_empty() {
            format!("{app}:{}", crate::native::title_hash(&title))
        } else {
            app.to_owned()
        };
        let address_bar = address_bar
            && self.state.browser_address_bar_enabled
            && self.address_bar_layout.is_some()
            && self
                .config
                .browser_address_bar_apps
                .iter()
                .any(|a| a == app);
        let previous = self.active.as_ref();
        let unchanged = previous.is_some_and(|c| c.key == key && c.address_bar == address_bar);
        let return_layout =
            if previous.is_some_and(|c| c.address_bar && c.key == key) && !address_bar {
                self.address_bar_previous_layout.take()
            } else {
                None
            };
        if address_bar && previous.is_some_and(|c| c.address_bar && c.key != key) {
            self.address_bar_previous_layout = None;
        }
        if address_bar && !previous.is_some_and(|c| c.address_bar) {
            if self.address_bar_previous_layout.is_none() && !self.current_layout.is_empty() {
                self.address_bar_previous_layout = Some(self.current_layout.clone());
            }
        } else if !address_bar {
            self.address_bar_previous_layout = None;
        }
        self.active = Some(Context {
            app: app.into(),
            title,
            key: key.clone(),
            window_id: window_id.into(),
            address_bar,
        });
        if unchanged {
            return None;
        }
        self.pending = None;
        if address_bar {
            return if self.paused {
                None
            } else {
                self.request(self.address_bar_layout.clone())
            };
        }
        self.clock += 1;
        let desired = self
            .state
            .entries
            .get_mut(&key)
            .map(|e| {
                self.dirty = true; // Persist recency on the next save or graceful exit.
                e.used = self.clock;
                e.layout.clone()
            })
            .or(return_layout)
            .or_else(|| {
                self.state.entries.get_mut(app).map(|e| {
                    self.dirty = true;
                    e.used = self.clock;
                    e.layout.clone()
                })
            })
            .or_else(|| self.state.default_layout.clone())
            .or_else(|| self.config.default_layout.clone());
        if self.paused {
            return None;
        }
        self.request(desired)
    }

    fn request(&mut self, desired: Option<String>) -> Option<String> {
        let desired = desired.filter(|s| !s.is_empty() && s != &self.current_layout)?;
        self.pending = Some(desired.clone());
        Some(desired)
    }

    /// The native backend confirms a successful selection synchronously. Later
    /// duplicate OS notifications cannot teach an automatic restore as manual.
    pub fn selected(&mut self, layout: &str, success: bool) {
        self.pending = None;
        if success {
            self.current_layout = layout.into();
        }
    }

    pub fn layout_changed(&mut self, layout: &str) -> bool {
        if layout.is_empty() || layout == self.current_layout {
            return false;
        }
        self.current_layout = layout.into();
        if self.pending.as_deref() == Some(layout) {
            self.pending = None;
            return false;
        }
        self.pending = None;
        if self.paused {
            return false;
        }
        if self.active.as_ref().is_some_and(|c| c.address_bar) {
            return false;
        }
        let Some(context) = self.active.clone() else {
            return false;
        };
        // The first manual choice establishes an app fallback. Later choices in
        // a title-tracked context do not overwrite that fallback for other tabs.
        if !self.state.entries.contains_key(&context.app) {
            self.remember(context.app, layout);
        }
        self.remember(context.key, layout);
        true
    }

    pub fn restore_address_bar_layout(&mut self) -> Option<String> {
        if self.paused || !self.active.as_ref().is_some_and(|c| c.address_bar) {
            return None;
        }
        self.request(self.address_bar_layout.clone())
    }

    pub fn set_address_bar_layout(&mut self, layout: Option<String>) {
        self.address_bar_layout = layout;
    }

    pub fn has_address_bar_layout(&self) -> bool {
        self.address_bar_layout.is_some()
    }

    pub fn toggle_browser_address_bar(&mut self) {
        self.state.browser_address_bar_enabled = !self.state.browser_address_bar_enabled;
        self.dirty = true;
    }

    fn remember(&mut self, key: String, layout: &str) {
        self.clock += 1;
        self.state.entries.insert(
            key,
            Entry {
                layout: layout.into(),
                used: self.clock,
            },
        );
        self.dirty = true;
        self.prune();
    }

    fn prune(&mut self) {
        while self.state.entries.len() > CAPACITY {
            let key = self
                .state
                .entries
                .iter()
                .min_by_key(|(_, v)| v.used)
                .unwrap()
                .0
                .clone();
            self.state.entries.remove(&key);
            self.dirty = true;
        }
    }

    pub fn toggle_pause(&mut self) -> Option<String> {
        self.paused = !self.paused;
        self.pending = None;
        if !self.paused
            && let Some(context) = self.active.take()
        {
            return self.focus_context(
                &context.app,
                &context.title,
                &context.window_id,
                context.address_bar,
            );
        }
        None
    }

    pub fn force_default(&mut self, layout: &str) -> Option<String> {
        self.state.default_layout = Some(layout.into());
        // Explicit override for the current context and its application's default.
        if let Some(context) = self.active.clone() {
            self.remember(context.app, layout);
            self.remember(context.key, layout);
        }
        self.dirty = true;
        self.request(Some(layout.into()))
    }

    pub fn clear(&mut self) {
        self.state.entries.clear();
        self.state.default_layout = None;
        self.pending = None;
        self.dirty = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn engine() -> Engine {
        let config = Config {
            title_tracking_apps: vec!["terminal".into()],
            ..Config::default()
        };
        let mut engine = Engine::new(config, State::default());
        engine.layout_changed("en");
        engine
    }

    #[test]
    fn tabs_restore_without_learning_automatic_changes() {
        let mut e = engine();
        assert_eq!(e.focus("terminal", "one"), None);
        assert!(e.layout_changed("ua"));
        e.focus("terminal", "two");
        assert!(e.layout_changed("en"));
        assert_eq!(e.focus("terminal", "one"), Some("ua".into()));
        assert!(!e.layout_changed("ua"));
        assert_eq!(e.focus("terminal", "two"), Some("en".into()));
        e.selected("en", true);
        assert!(!e.layout_changed("en"));
        assert_eq!(e.state.entries.len(), 3);
    }

    #[test]
    fn native_tabs_with_identical_titles_keep_separate_layouts() {
        let mut e = engine();
        e.focus_window("terminal", "same title", "window-a");
        e.layout_changed("ua");
        e.focus_window("terminal", "same title", "window-b");
        e.layout_changed("en");
        assert_eq!(
            e.focus_window("terminal", "same title", "window-a"),
            Some("ua".into())
        );
        e.selected("ua", true);
        assert_eq!(
            e.focus_window("terminal", "same title", "window-b"),
            Some("en".into())
        );
        assert_eq!(e.active.as_ref().unwrap().title, "same title");
        assert_eq!(e.focus_window("terminal", "new title", "window-b"), None);
        assert_eq!(e.active.as_ref().unwrap().title, "new title");
    }

    #[test]
    fn browser_address_bar_uses_temporary_layout_without_learning() {
        let mut e = engine();
        e.set_address_bar_layout(Some("en".into()));
        e.focus("com.google.Chrome", "example");
        e.layout_changed("ua");
        let learned = e.state.entries.clone();
        assert_eq!(
            e.focus_context("com.google.Chrome", "example", "", true),
            Some("en".into())
        );
        e.selected("en", true);
        assert!(!e.layout_changed("de"));
        assert_eq!(e.restore_address_bar_layout(), Some("en".into()));
        e.selected("en", true);
        assert_eq!(e.state.entries, learned);
        assert_eq!(
            e.focus_context("com.google.Chrome", "example", "", false),
            Some("ua".into())
        );
    }

    #[test]
    fn address_bar_restores_prior_layout_for_unknown_context() {
        let mut e = engine();
        e.set_address_bar_layout(Some("en".into()));
        e.config.title_tracking_apps.push("com.apple.Safari".into());
        e.focus("com.apple.Safari", "new tab");
        e.current_layout = "ua".into();
        e.state.entries.insert(
            "com.apple.Safari".into(),
            Entry {
                layout: "en".into(),
                used: 1,
            },
        );
        assert_eq!(
            e.focus_context("com.apple.Safari", "new tab", "", true),
            Some("en".into())
        );
        e.selected("en", true);
        assert_eq!(e.current_layout, "en");
        assert_eq!(e.address_bar_previous_layout.as_deref(), Some("ua"));
        assert!(e.active.as_ref().unwrap().address_bar);
        assert_eq!(
            e.focus_context("com.apple.Safari", "new tab", "", false),
            Some("ua".into())
        );
        assert_eq!(e.state.entries.len(), 1);
    }

    #[test]
    fn address_bar_setting_is_limited_to_configured_browsers() {
        let mut e = engine();
        e.set_address_bar_layout(Some("en".into()));
        e.config.browser_address_bar_apps = vec!["com.google.Chrome".into()];
        assert_eq!(e.focus_context("com.apple.Safari", "tab", "", true), None);
        assert!(!e.active.as_ref().unwrap().address_bar);
    }

    #[test]
    fn address_bar_toggle_persists_and_old_state_defaults_to_enabled() {
        let old = r#"{"version":1,"entries":{},"default_layout":null}"#;
        let state: State = serde_json::from_str(old).unwrap();
        assert!(state.browser_address_bar_enabled);
        let mut e = Engine::new(Config::default(), state);
        e.set_address_bar_layout(Some("en".into()));
        e.toggle_browser_address_bar();
        assert!(e.dirty);
        assert!(!e.state.browser_address_bar_enabled);
        assert_eq!(e.focus_context("com.google.Chrome", "tab", "", true), None);
        assert!(!e.active.as_ref().unwrap().address_bar);
        let saved = serde_json::to_string(&e.state).unwrap();
        assert!(
            !serde_json::from_str::<State>(&saved)
                .unwrap()
                .browser_address_bar_enabled
        );
        e.toggle_browser_address_bar();
        assert_eq!(
            e.focus_context("com.google.Chrome", "tab", "", true),
            Some("en".into())
        );
    }

    #[test]
    fn disabling_address_bar_while_focused_restores_prior_layout() {
        let mut e = engine();
        e.set_address_bar_layout(Some("en".into()));
        e.focus("com.apple.Safari", "new tab");
        e.current_layout = "ua".into();
        let desired = e.focus_context("com.apple.Safari", "new tab", "", true);
        assert_eq!(desired, Some("en".into()));
        e.selected("en", true);
        e.toggle_browser_address_bar();
        // macOS re-reads the focused element after the toggle.
        assert_eq!(
            e.focus_context("com.apple.Safari", "new tab", "", true),
            Some("ua".into())
        );
        assert!(!e.active.as_ref().unwrap().address_bar);
    }

    #[test]
    fn pausing_in_address_bar_keeps_prior_layout_for_exit() {
        let mut e = engine();
        e.set_address_bar_layout(Some("en".into()));
        e.focus("com.apple.Safari", "new tab");
        e.current_layout = "ua".into();
        assert_eq!(
            e.focus_context("com.apple.Safari", "new tab", "", true),
            Some("en".into())
        );
        e.selected("en", true);
        e.toggle_pause();
        assert_eq!(e.toggle_pause(), None);
        assert_eq!(
            e.focus_context("com.apple.Safari", "new tab", "", false),
            Some("ua".into())
        );
    }

    #[test]
    fn new_tabs_use_app_fallback_unknown_apps_keep_current() {
        let mut e = engine();
        e.focus("terminal", "one");
        e.layout_changed("ua");
        e.focus("other", "");
        e.layout_changed("en");
        assert_eq!(e.focus("terminal", "new"), Some("ua".into()));
        e.selected("ua", true);
        assert_eq!(e.focus("unknown", ""), None);
    }

    #[test]
    fn pause_freezes_learning_and_resume_restores() {
        let mut e = engine();
        e.focus("terminal", "one");
        e.layout_changed("ua");
        e.toggle_pause();
        assert!(!e.layout_changed("en"));
        assert_eq!(e.toggle_pause(), Some("ua".into()));
    }

    #[test]
    fn failed_restore_does_not_suppress_next_manual_change() {
        let mut e = engine();
        e.focus("app", "");
        e.layout_changed("ua");
        e.focus("other", "");
        e.layout_changed("en");
        assert_eq!(e.focus("app", ""), Some("ua".into()));
        e.selected("ua", false);
        assert!(e.layout_changed("de"));
        assert_eq!(e.state.entries["app"].layout, "de");
    }

    #[test]
    fn lru_evicts_least_recently_used_including_defaults() {
        let mut e = engine();
        for i in 0..CAPACITY {
            e.focus(&format!("app{i}"), "");
            e.layout_changed(if i % 2 == 0 { "ua" } else { "en" });
        }
        e.focus("app0", "");
        e.selected("ua", true);
        e.focus("new", "");
        e.layout_changed("de");
        assert_eq!(e.state.entries.len(), CAPACITY);
        assert!(e.state.entries.contains_key("app0"));
        assert!(!e.state.entries.contains_key("app1"));
    }

    #[test]
    fn title_normalization_is_conservative_and_hash_is_sha256() {
        let mut e = engine();
        e.focus("terminal", " hello\n world ");
        assert_eq!(e.active.as_ref().unwrap().key, "terminal:b94d27b9934d3e08");
        e.layout_changed("ua");
        assert_eq!(e.focus("terminal", "hello world"), None);
        e.focus("terminal", "Hello world");
        assert_ne!(e.active.unwrap().key, "terminal:b94d27b9934d3e08");
    }

    #[test]
    fn clear_removes_defaults_and_entries() {
        let mut e = engine();
        e.focus("app", "");
        e.force_default("ua");
        e.clear();
        assert!(e.state.entries.is_empty());
        assert!(e.state.default_layout.is_none());
        assert!(e.dirty);
    }
}
