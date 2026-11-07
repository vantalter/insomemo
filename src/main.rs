mod config;
mod engine;
mod native;
mod storage;
#[cfg(any(target_os = "linux", test))]
mod wayland;

use config::Config;
use engine::Engine;
use native::{Layout, cstring};
use std::{
    cell::RefCell,
    ffi::{CStr, c_char},
    path::PathBuf,
};
use storage::Store;

struct App {
    engine: Engine,
    store: Store,
    layouts: Vec<Layout>,
    error: String,
    /// Persistent condition (missing permission) shown when no error is active.
    warning: String,
    save_failed: bool,
    fatal_error: Option<String>,
}

thread_local! {
    static APP: RefCell<Option<App>> = const { RefCell::new(None) };
    #[cfg(target_os = "linux")]
    static WAYLAND: RefCell<Option<wayland::Backend>> = const { RefCell::new(None) };
}

fn installed_layouts() -> Result<Vec<Layout>, String> {
    #[cfg(target_os = "linux")]
    if let Some(result) = WAYLAND.with(|w| w.borrow_mut().as_mut().map(|b| b.layouts())) {
        return result;
    }
    native::layouts()
}

fn select_layout(layout: &str) -> bool {
    #[cfg(target_os = "linux")]
    if let Some(result) = WAYLAND.with(|w| w.borrow_mut().as_mut().map(|b| b.select(layout))) {
        if let Err(e) = &result {
            eprintln!("insomemo: {e}");
        }
        return result.is_ok();
    }
    unsafe { native::native_set_layout(cstring(layout).as_ptr()) != 0 }
}

fn update_tray() {
    APP.with(|slot| {
        let borrow = slot.borrow();
        let Some(app) = borrow.as_ref() else {
            return;
        };
        let engine = &app.engine;
        let context = engine
            .active
            .as_ref()
            .map(|c| {
                let title: String = c.title.chars().take(100).collect();
                if title.is_empty() {
                    c.app.clone()
                } else {
                    format!("{}: {title}", c.app)
                }
            })
            .unwrap_or_else(|| "No focused application".into());
        let layouts = serde_json::to_string(&app.layouts).unwrap();
        let message = if app.error.is_empty() {
            &app.warning
        } else {
            &app.error
        };
        unsafe {
            native::native_update(
                cstring(&context).as_ptr(),
                engine.paused as i32,
                cstring(message).as_ptr(),
                cstring(&layouts).as_ptr(),
            );
        }
    });
}

fn flush() {
    APP.with(|slot| {
        let mut borrow = slot.borrow_mut();
        let Some(app) = borrow.as_mut() else {
            return;
        };
        if app.engine.dirty {
            match app.store.save(&app.engine.state) {
                Ok(()) => {
                    app.engine.dirty = false;
                    if app.save_failed {
                        app.error.clear();
                    }
                    app.save_failed = false;
                }
                Err(e) => {
                    eprintln!("insomemo: {e}");
                    app.error = e;
                    app.save_failed = true;
                }
            }
        }
    });
}

fn event(kind: &str, first: &str, second: &str) {
    event_with_context(kind, first, second, "");
}

fn event_with_context(kind: &str, first: &str, second: &str, window_id: &str) {
    if kind == "fatal" {
        APP.with(|slot| {
            if let Some(app) = slot.borrow_mut().as_mut() {
                app.fatal_error = Some(first.to_owned());
            }
        });
        event("error", first, "");
        event("quit", "", "");
        return;
    }
    #[cfg(target_os = "linux")]
    if kind == "refresh-layout" {
        let result = WAYLAND.with(|w| w.borrow().as_ref().map(|b| b.current_layout()));
        if let Some(result) = result {
            match result {
                Ok(e) => event(&e.0, &e.1, &e.2),
                Err(e) => event("error", &e, ""),
            }
        }
        return;
    }
    #[cfg(target_os = "linux")]
    if kind == "io" || kind == "ready" {
        let events = WAYLAND.with(|w| {
            w.borrow_mut().as_mut().map(|b| {
                if kind == "ready" {
                    b.snapshot()
                } else {
                    b.events()
                }
            })
        });
        if let Some(events) = events {
            match events {
                Ok(events) => {
                    for e in events {
                        event(&e.0, &e.1, &e.2);
                    }
                }
                Err(e) => event("fatal", &e, ""),
            }
        }
        if kind == "io" {
            return;
        }
    }
    if kind == "flush" {
        flush();
        update_tray();
        return;
    }
    if kind == "quit" {
        flush();
        unsafe {
            native::native_stop();
        }
        return;
    }
    if kind == "layouts" || kind == "ready" {
        match installed_layouts() {
            Ok(layouts) => APP.with(|s| {
                if let Some(app) = s.borrow_mut().as_mut() {
                    app.layouts = layouts;
                }
            }),
            Err(e) => event("error", &e, ""),
        }
    }
    let (desired, save) = APP.with(|slot| {
        let mut borrow = slot.borrow_mut();
        let Some(app) = borrow.as_mut() else {
            return (None, false);
        };
        let engine = &mut app.engine;
        let mut save = false;
        let desired = match kind {
            "context" => engine.focus_window(first, second, window_id),
            "layout" => {
                save = engine.layout_changed(first);
                None
            }
            "pause" => engine.toggle_pause(),
            "default" => {
                if app.layouts.iter().any(|l| l.id == first) {
                    save = true;
                    engine.force_default(first)
                } else {
                    app.error = "That keyboard layout is no longer installed".into();
                    None
                }
            }
            "clear" => {
                engine.clear();
                save = true;
                None
            }
            "warning" => {
                app.warning = first.into();
                None
            }
            "error" => {
                eprintln!("insomemo: {first}");
                app.error = first.into();
                None
            }
            _ => None,
        };
        (desired, save)
    });
    if let Some(layout) = desired {
        let success = select_layout(&layout);
        APP.with(|slot| {
            if let Some(app) = slot.borrow_mut().as_mut() {
                app.engine.selected(&layout, success);
                if success {
                    if !app.save_failed {
                        app.error.clear();
                    }
                } else {
                    app.error = format!("Cannot select layout {layout}; check installed layouts");
                }
            }
        });
    }
    if save {
        unsafe {
            native::native_schedule_save();
        }
    }
    update_tray();
}

/// # Safety
/// Called on the main thread with non-null, NUL-terminated strings valid for
/// the duration of this callback. Native code must not retain Rust references.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn switcher_event(
    kind: *const c_char,
    first: *const c_char,
    second: *const c_char,
) {
    // Native code guarantees non-null, UTF-8 strings valid for the callback.
    let string = |p| unsafe { CStr::from_ptr(p).to_string_lossy().into_owned() };
    event(&string(kind), &string(first), &string(second));
}

/// # Safety
/// Strings are non-null, NUL-terminated, and valid for this callback on the main thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn switcher_context(
    app: *const c_char,
    title: *const c_char,
    window_id: *const c_char,
) {
    let string = |p| unsafe { CStr::from_ptr(p).to_string_lossy().into_owned() };
    let (app, title, window_id) = (string(app), string(title), string(window_id));
    event_with_context("context", &app, &title, &window_id);
}

fn run() -> Result<(), String> {
    let config_root = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
        .ok_or("HOME or XDG_CONFIG_HOME must be set")?;
    let mut dir = config_root.join("insomemo");
    // Keep existing users' learned layouts and the same instance lock. New
    // installations use the new name; explicit --state-dir still takes priority.
    let legacy_dir = config_root.join("input-switcher");
    if !dir.exists() && legacy_dir.is_dir() {
        dir = legacy_dir;
    }
    let mut config_path = None;
    let mut check = false;
    let mut list = false;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--help" | "-h" => {
                println!(
                    "insomemo — context-aware keyboard layout memory\n\nUsage: insomemo [--config PATH] [--state-dir DIR]\n       insomemo --check | --list-layouts | --print-default-config\n\n--check                 Validate configuration and state without starting the daemon\n--list-layouts          Print installed layout IDs as JSON\n--print-default-config  Print the optional config.json template\n--state-dir DIR         Override the private configuration/state directory\n--config PATH           Read configuration from a different JSON file\n--version              Print version\n\nmacOS: grant Accessibility access for window/tab tracking.\nLinux: X11, Sway, and Hyprland; requires a StatusNotifier tray host."
                );
                return Ok(());
            }
            "--version" | "-V" => {
                println!("insomemo {}", env!("CARGO_PKG_VERSION"));
                return Ok(());
            }
            "--print-default-config" => {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&Config::default()).unwrap()
                );
                return Ok(());
            }
            "--config" => {
                config_path = Some(PathBuf::from(
                    args.next().ok_or("--config requires a path")?,
                ))
            }
            "--state-dir" => dir = PathBuf::from(args.next().ok_or("--state-dir requires a path")?),
            "--check" => check = true,
            "--list-layouts" => list = true,
            _ => return Err(format!("Unknown argument {arg}; use --help")),
        }
    }
    let config = Config::load(&config_path.unwrap_or_else(|| dir.join("config.json")))?;
    if check {
        let store = Store::open(&dir)?;
        let state = store.load()?;
        println!(
            "Configuration valid; {} saved contexts; state: {}",
            state.entries.len(),
            store.path.display()
        );
        return Ok(());
    }
    #[allow(unused_mut)]
    let mut fd = -1;
    #[cfg(target_os = "linux")]
    if let Some(backend) = wayland::Backend::detect(config.keyboard.clone())? {
        fd = backend.fd();
        WAYLAND.with(|w| *w.borrow_mut() = Some(backend));
    }
    if list {
        println!(
            "{}",
            serde_json::to_string_pretty(&installed_layouts()?).unwrap()
        );
        return Ok(());
    }
    let store = Store::open(&dir)?;
    let state = store.load()?;
    APP.with(|slot| {
        *slot.borrow_mut() = Some(App {
            engine: Engine::new(config, state),
            store,
            layouts: Vec::new(),
            error: String::new(),
            warning: String::new(),
            save_failed: false,
            fatal_error: None,
        })
    });
    let status = unsafe { native::native_run(fd) };
    flush();
    let save_failed = APP.with(|slot| slot.borrow().as_ref().is_some_and(|app| app.save_failed));
    if status != 0 {
        return Err(format!("Platform backend stopped with status {status}"));
    }
    if let Some(error) = APP.with(|slot| {
        slot.borrow()
            .as_ref()
            .and_then(|app| app.fatal_error.clone())
    }) {
        return Err(error);
    }
    if save_failed {
        return Err("State could not be saved; see error above".into());
    }
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("insomemo: {error}");
        std::process::exit(1);
    }
}
