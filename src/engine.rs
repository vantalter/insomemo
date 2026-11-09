use crate::config::Config;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const CAPACITY: usize = 200;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Entry {
    pub layout: String,
    pub used: u64,
}

/// Unknown fields are ignored so a downgrade can read state from a newer build;
/// incompatible formats must bump `version` instead.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct State {
    pub version: u32,
    pub entries: BTreeMap<String, Entry>,
    #[serde(default)]
    pub default_layout: Option<String>,
    /// Explicit "always use this layout" rules; they beat learned layouts and
    /// are never evicted or cleared with the cache.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub pins: BTreeMap<String, String>,
    /// Tray preference: briefly badge the icon after an automatic switch.
    #[serde(default = "enabled")]
    pub show_switch_indicator: bool,
    /// Corner of the tray icon that carries the badge (macOS).
    #[serde(default)]
    pub switch_indicator_position: IndicatorPosition,
}

fn enabled() -> bool {
    true
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum IndicatorPosition {
    BottomRight,
    /// Also used for positions written by a newer build that this one lacks;
    /// serde requires this catch-all to be the last variant.
    #[default]
    #[serde(other)]
    TopRight,
}

impl IndicatorPosition {
    pub fn id(self) -> &'static str {
        match self {
            IndicatorPosition::TopRight => "top-right",
            IndicatorPosition::BottomRight => "bottom-right",
        }
    }
}

impl Default for State {
    fn default() -> Self {
        Self {
            version: 1,
            entries: BTreeMap::new(),
            default_layout: None,
            pins: BTreeMap::new(),
            show_switch_indicator: true,
            switch_indicator_position: IndicatorPosition::TopRight,
        }
    }
}

/// How much of the focused context a pin or forget action applies to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    Tab,
    Site,
    App,
}

impl Scope {
    pub const ALL: [Scope; 3] = [Scope::Tab, Scope::Site, Scope::App];

    pub fn id(self) -> &'static str {
        match self {
            Scope::Tab => "tab",
            Scope::Site => "site",
            Scope::App => "app",
        }
    }

    pub fn parse(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|scope| scope.id() == id)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Context {
    pub app: String,
    pub title: String,
    pub key: String,
    pub window_id: String,
    /// Window identities do not survive an app restart, so they are not persisted.
    pub session: bool,
    /// Browser host; its context is the fallback between a page and the app.
    pub site: String,
    pub site_key: Option<String>,
}

pub struct Engine {
    pub config: Config,
    pub state: State,
    pub active: Option<Context>,
    pub current_layout: String,
    pub paused: bool,
    pub dirty: bool,
    pending: Option<String>,
    /// Session-only contexts keyed by window identity; bounded like `state.entries`.
    windows: BTreeMap<String, Entry>,
    /// Pins on session-only contexts, which cannot be persisted either.
    window_pins: BTreeMap<String, String>,
    clock: u64,
}

impl Engine {
    pub fn new(config: Config, mut state: State) -> Self {
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
            windows: BTreeMap::new(),
            window_pins: BTreeMap::new(),
            clock,
        };
        engine.prune();
        engine
    }

    #[cfg(test)]
    pub fn focus(&mut self, app: &str, title: &str) -> Option<String> {
        self.focus_window(app, title, "")
    }

    #[cfg(test)]
    pub fn focus_window(&mut self, app: &str, title: &str, window_id: &str) -> Option<String> {
        self.focus_site(app, title, window_id, "")
    }

    pub fn focus_site(
        &mut self,
        app: &str,
        title: &str,
        window_id: &str,
        site: &str,
    ) -> Option<String> {
        if app.is_empty() {
            self.active = None;
            self.pending = None;
            return None;
        }
        let title = self.config.clean_title(title);
        let track = self.config.title_tracking_apps.iter().any(|a| a == app);
        let session = track && !window_id.is_empty();
        let key = if session {
            format!(
                "{app}:{}",
                crate::native::title_hash(&format!("window:{window_id}"))
            )
        } else if track && !title.is_empty() {
            format!("{app}:{}", crate::native::title_hash(&title))
        } else {
            app.to_owned()
        };
        let site_key = (track && !site.is_empty()).then(|| {
            format!(
                "{app}:{}",
                crate::native::title_hash(&format!("site:{site}"))
            )
        });
        let unchanged = self.active.as_ref().is_some_and(|c| c.key == key);
        self.active = Some(Context {
            app: app.into(),
            title,
            key: key.clone(),
            window_id: window_id.into(),
            session,
            site: site.into(),
            site_key: site_key.clone(),
        });
        if unchanged {
            return None;
        }
        self.pending = None;
        let session_pin = if session {
            self.window_pins.get(&key)
        } else {
            None
        };
        let pinned = session_pin
            .or_else(|| self.state.pins.get(&key))
            .or_else(|| self.state.pins.get(site_key.as_ref()?))
            .or_else(|| self.state.pins.get(app))
            .cloned();
        if pinned.is_some() {
            return if self.paused {
                None
            } else {
                self.request(pinned)
            };
        }
        self.clock += 1;
        let exact = if session {
            self.windows.get_mut(&key).map(|e| {
                e.used = self.clock;
                e.layout.clone()
            })
        } else {
            self.state.entries.get_mut(&key).map(|e| {
                self.dirty = true; // Persist recency on the next save or graceful exit.
                e.used = self.clock;
                e.layout.clone()
            })
        };
        let desired = exact
            .or_else(|| {
                let entry = self.state.entries.get_mut(site_key.as_ref()?)?;
                self.dirty = true;
                entry.used = self.clock;
                Some(entry.layout.clone())
            })
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
        let Some(context) = self.active.clone() else {
            return false;
        };
        // The first manual choice establishes an app fallback. Later choices in
        // a title-tracked context do not overwrite that fallback for other tabs.
        if !self.state.entries.contains_key(&context.app) {
            self.remember(context.app, layout, false);
        }
        // A site follows its latest choice, so new pages on it start there.
        if let Some(site_key) = context.site_key {
            self.remember(site_key, layout, false);
        }
        self.remember(context.key, layout, context.session);
        true
    }

    fn remember(&mut self, key: String, layout: &str, session: bool) {
        self.clock += 1;
        let entry = Entry {
            layout: layout.into(),
            used: self.clock,
        };
        if session {
            self.windows.insert(key, entry);
            evict_least_recent(&mut self.windows);
        } else {
            self.state.entries.insert(key, entry);
            self.dirty = true;
            self.prune();
        }
    }

    fn prune(&mut self) {
        if evict_least_recent(&mut self.state.entries) {
            self.dirty = true;
        }
    }

    pub fn toggle_pause(&mut self) -> Option<String> {
        self.paused = !self.paused;
        self.pending = None;
        if !self.paused
            && let Some(context) = self.active.take()
        {
            return self.focus_site(
                &context.app,
                &context.title,
                &context.window_id,
                &context.site,
            );
        }
        None
    }

    pub fn force_default(&mut self, layout: &str) -> Option<String> {
        self.state.default_layout = Some(layout.into());
        // Explicit override for the current context and its application's default.
        if let Some(context) = self.active.clone() {
            self.remember(context.app, layout, false);
            if let Some(site_key) = context.site_key {
                self.remember(site_key, layout, false);
            }
            self.remember(context.key, layout, context.session);
        }
        self.dirty = true;
        self.request(Some(layout.into()))
    }

    /// The stored key for `scope` of the focused context, and whether it is session-only.
    fn scope_key(&self, scope: Scope) -> Option<(String, bool)> {
        let context = self.active.as_ref()?;
        match scope {
            Scope::Tab => {
                (context.key != context.app).then(|| (context.key.clone(), context.session))
            }
            Scope::Site => context.site_key.clone().map(|key| (key, false)),
            Scope::App => Some((context.app.clone(), false)),
        }
    }

    /// Scopes available for the focused context, with their pin and whether
    /// a learned layout exists to forget.
    pub fn scopes(&self) -> Vec<(Scope, Option<String>, bool)> {
        Scope::ALL
            .into_iter()
            .filter_map(|scope| {
                let (key, session) = self.scope_key(scope)?;
                let (pins, entries) = if session {
                    (&self.window_pins, &self.windows)
                } else {
                    (&self.state.pins, &self.state.entries)
                };
                Some((scope, pins.get(&key).cloned(), entries.contains_key(&key)))
            })
            .collect()
    }

    pub fn pin_count(&self) -> usize {
        self.state.pins.len() + self.window_pins.len()
    }

    /// Pins the current layout to `scope`, or removes an existing pin there.
    /// Returns whether persistent state changed.
    pub fn toggle_pin(&mut self, scope: Scope) -> bool {
        let Some((key, session)) = self.scope_key(scope) else {
            return false;
        };
        let pins = if session {
            &mut self.window_pins
        } else {
            &mut self.state.pins
        };
        if pins.remove(&key).is_none() {
            if self.current_layout.is_empty() {
                return false;
            }
            pins.insert(key, self.current_layout.clone());
        }
        if !session {
            self.dirty = true;
        }
        !session
    }

    /// Removes the learned layout for `scope`; pins are unaffected.
    /// Returns whether persistent state changed.
    pub fn forget(&mut self, scope: Scope) -> bool {
        let Some((key, session)) = self.scope_key(scope) else {
            return false;
        };
        if session {
            self.windows.remove(&key);
            return false;
        }
        let removed = self.state.entries.remove(&key).is_some();
        self.dirty |= removed;
        removed
    }

    pub fn toggle_switch_indicator(&mut self) {
        self.state.show_switch_indicator = !self.state.show_switch_indicator;
        self.dirty = true;
    }

    /// `None` turns the indicator off; a position turns it on in that corner.
    pub fn set_switch_indicator(&mut self, position: Option<IndicatorPosition>) {
        self.state.show_switch_indicator = position.is_some();
        if let Some(position) = position {
            self.state.switch_indicator_position = position;
        }
        self.dirty = true;
    }

    pub fn clear_pins(&mut self) {
        self.state.pins.clear();
        self.window_pins.clear();
        self.dirty = true;
    }

    pub fn clear(&mut self) {
        self.state.entries.clear();
        self.windows.clear();
        self.state.default_layout = None;
        self.pending = None;
        self.dirty = true;
    }
}

/// Trims `entries` to `CAPACITY`; returns whether anything was evicted.
fn evict_least_recent(entries: &mut BTreeMap<String, Entry>) -> bool {
    let mut evicted = false;
    while entries.len() > CAPACITY {
        let key = entries
            .iter()
            .min_by_key(|(_, v)| v.used)
            .unwrap()
            .0
            .clone();
        entries.remove(&key);
        evicted = true;
    }
    evicted
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

    #[test]
    fn resume_keeps_window_identity() {
        let mut e = engine();
        e.focus_window("terminal", "same title", "window-a");
        assert!(e.layout_changed("ua"));
        e.focus_window("terminal", "same title", "window-b");
        assert!(e.layout_changed("en"));
        e.focus_window("terminal", "same title", "window-a");
        e.selected("ua", true);
        e.toggle_pause();
        e.current_layout = "en".into();
        assert_eq!(e.toggle_pause(), Some("ua".into()));
        assert_eq!(e.focus_window("terminal", "same title", "window-a"), None);
    }

    #[test]
    fn window_identities_are_remembered_only_for_the_session() {
        let mut e = engine();
        e.focus_window("terminal", "shell", "window-a");
        assert!(e.layout_changed("ua"));
        e.focus_window("terminal", "shell", "window-b");
        assert!(e.layout_changed("en"));
        assert_eq!(
            e.focus_window("terminal", "shell", "window-a"),
            Some("ua".into())
        );
        // Only the app fallback is persisted; window keys never reach state.json.
        assert_eq!(e.state.entries.keys().collect::<Vec<_>>(), vec!["terminal"]);
        e.clear();
        e.selected("ua", true);
        assert_eq!(e.focus_window("terminal", "shell", "window-b"), None);
    }

    #[test]
    fn state_from_newer_build_loads() {
        let newer = r#"{"version":1,"entries":{},"default_layout":"ua","future_flag":true}"#;
        let state: State = serde_json::from_str(newer).unwrap();
        assert_eq!(state.default_layout.as_deref(), Some("ua"));
    }

    #[test]
    fn new_pages_on_a_site_use_its_latest_layout() {
        let mut e = engine();
        e.config.title_tracking_apps.push("browser".into());
        e.focus_site("browser", "Search", "", "google.com");
        assert!(e.layout_changed("ua"));
        e.focus_site("browser", "News", "", "bbc.co.uk");
        assert!(e.layout_changed("de"));
        // An unseen page uses its site's latest choice, not the app fallback (ua).
        assert_eq!(e.focus_site("browser", "Weather", "", "bbc.co.uk"), None);
        assert_eq!(
            e.focus_site("browser", "Docs", "", "google.com"),
            Some("ua".into())
        );
        e.selected("ua", true);
        // A page's own choice still wins over its site's latest choice.
        assert!(e.layout_changed("en"));
        assert_eq!(
            e.focus_site("browser", "Search", "", "google.com"),
            Some("ua".into())
        );
    }

    #[test]
    fn pins_beat_learned_layouts_until_removed() {
        let mut e = engine();
        e.config.title_tracking_apps.push("browser".into());
        e.focus_site("browser", "Search", "", "google.com");
        assert!(e.layout_changed("ua"));
        e.focus_site("browser", "Mail", "", "google.com");
        e.selected("ua", true);
        assert!(e.layout_changed("en"));
        assert!(e.toggle_pin(Scope::App));
        assert_eq!(e.scopes()[2], (Scope::App, Some("en".into()), true));
        // The app pin overrides the learned page and site layouts (ua).
        e.focus_site("browser", "Search", "", "google.com");
        assert_eq!(e.focus_site("browser", "Docs", "", "google.com"), None);
        // Manual changes while pinned do not move the pin.
        assert!(e.layout_changed("ua"));
        assert_eq!(
            e.focus_site("browser", "Mail", "", "google.com"),
            Some("en".into())
        );
        e.selected("en", true);
        // Pins survive Clear Cache and persist; removing one restores learning.
        e.clear();
        let saved: State = serde_json::from_str(&serde_json::to_string(&e.state).unwrap()).unwrap();
        assert_eq!(saved.pins.len(), 1);
        assert!(e.toggle_pin(Scope::App));
        assert_eq!(e.pin_count(), 0);
    }

    #[test]
    fn forget_removes_only_the_chosen_scope() {
        let mut e = engine();
        e.focus("terminal", "build");
        assert!(e.layout_changed("ua"));
        assert!(e.forget(Scope::Tab));
        assert!(!e.forget(Scope::Tab));
        assert!(e.state.entries.contains_key("terminal"));
        // Untracked apps have no tab scope.
        e.focus("editor", "file.rs");
        assert_eq!(e.scopes().len(), 1);
        assert!(!e.toggle_pin(Scope::Tab));
    }

    #[test]
    fn session_tab_pins_are_not_persisted() {
        let mut e = engine();
        e.focus_window("terminal", "shell", "window-a");
        assert!(!e.toggle_pin(Scope::Tab));
        assert_eq!(e.scopes()[0].1, Some("en".into()));
        assert!(e.state.pins.is_empty());
        e.focus_window("terminal", "shell", "window-b");
        e.layout_changed("ua");
        assert_eq!(
            e.focus_window("terminal", "shell", "window-a"),
            Some("en".into())
        );
    }

    #[test]
    fn switch_indicator_defaults_on_and_persists_when_off() {
        let old: State = serde_json::from_str(r#"{"version":1,"entries":{}}"#).unwrap();
        assert!(old.show_switch_indicator);
        let mut e = Engine::new(Config::default(), old);
        e.toggle_switch_indicator();
        assert!(e.dirty);
        let saved: State = serde_json::from_str(&serde_json::to_string(&e.state).unwrap()).unwrap();
        assert!(!saved.show_switch_indicator);
    }

    #[test]
    fn indicator_position_persists_and_tolerates_unknown_values() {
        let mut e = engine();
        e.set_switch_indicator(Some(IndicatorPosition::BottomRight));
        let saved = serde_json::to_string(&e.state).unwrap();
        assert!(saved.contains(r#""switch_indicator_position":"bottom-right""#));
        let state: State = serde_json::from_str(&saved).unwrap();
        assert_eq!(
            state.switch_indicator_position,
            IndicatorPosition::BottomRight
        );
        // Turning it off keeps the corner for when it is turned back on.
        e.set_switch_indicator(None);
        assert!(!e.state.show_switch_indicator);
        assert_eq!(
            e.state.switch_indicator_position,
            IndicatorPosition::BottomRight
        );
        let newer = r#"{"version":1,"entries":{},"switch_indicator_position":"centre"}"#;
        let state: State = serde_json::from_str(newer).unwrap();
        assert_eq!(state.switch_indicator_position, IndicatorPosition::TopRight);
    }
}
