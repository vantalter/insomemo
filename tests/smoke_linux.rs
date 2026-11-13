//! Linux runtime smoke test: real tray RPC over D-Bus, debounced saving, and a
//! clean exit. It needs an X server and a session bus, so it is ignored by
//! default; CI runs it with
//! `dbus-run-session -- xvfb-run -a cargo test --release --test smoke_linux -- --ignored`.
#![cfg(target_os = "linux")]
use std::{
    path::Path,
    process::{Child, Command, Stdio},
    thread::sleep,
    time::{Duration, Instant},
};

fn command(program: &str) -> Command {
    let mut command = Command::new(program);
    for key in ["WAYLAND_DISPLAY", "SWAYSOCK", "HYPRLAND_INSTANCE_SIGNATURE"] {
        command.env_remove(key);
    }
    command.env("XDG_SESSION_TYPE", "x11");
    command
}

fn call(destination: &str, path: &str, method: &str, arguments: &[&str]) -> Option<String> {
    let output = command("gdbus")
        .args([
            "call",
            "--session",
            "--dest",
            destination,
            "--object-path",
            path,
        ])
        .args(["--method", method, "--"])
        .args(arguments)
        .stderr(Stdio::null())
        .output()
        .expect("gdbus must be installed");
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Kills the daemon if an assertion fails before it is stopped.
struct Daemon(Child);

impl Drop for Daemon {
    fn drop(&mut self) {
        if self.0.try_wait().ok().flatten().is_none() {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
}

fn find_tray(daemon: &mut Daemon) -> String {
    // Bounded readiness retry in the test harness; the daemon has no polling.
    for _ in 0..30 {
        assert!(
            daemon.0.try_wait().unwrap().is_none(),
            "Daemon exited during initialization"
        );
        let names = call(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus.ListNames",
            &[],
        )
        .expect("session bus must be running");
        for name in names.split('\'').filter(|n| n.starts_with(':')) {
            let id = call(
                name,
                "/StatusNotifierItem",
                "org.freedesktop.DBus.Properties.Get",
                &["org.kde.StatusNotifierItem", "Id"],
            );
            if id.is_some_and(|id| id.contains("insomemo")) {
                return name.to_owned();
            }
        }
        sleep(Duration::from_millis(100));
    }
    panic!("StatusNotifierItem was not registered");
}

fn read_state(dir: &Path) -> serde_json::Value {
    serde_json::from_str(&std::fs::read_to_string(dir.join("state.json")).unwrap()).unwrap()
}

#[test]
#[ignore = "needs an X server and a session bus"]
fn tray_pause_default_debounce_clear_and_shutdown() {
    let binary = env!("CARGO_BIN_EXE_insomemo");
    let layouts = command(binary).arg("--list-layouts").output().unwrap();
    let layouts: serde_json::Value = serde_json::from_slice(&layouts.stdout).unwrap();
    assert!(
        layouts.as_array().is_some_and(|l| !l.is_empty()),
        "XKB must expose at least one layout"
    );
    let dir = std::env::temp_dir().join(format!("insomemo-linux-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let mut daemon = Daemon(
        command(binary)
            .arg("--state-dir")
            .arg(&dir)
            .spawn()
            .unwrap(),
    );
    let owner = find_tray(&mut daemon);

    let menu = || {
        call(
            &owner,
            "/MenuBar",
            "com.canonical.dbusmenu.GetLayout",
            &["0", "-1", "[]"],
        )
        .unwrap()
    };
    let click = |id: &str| {
        call(
            &owner,
            "/MenuBar",
            "com.canonical.dbusmenu.Event",
            &[id, "clicked", "<0>", "0"],
        )
        .unwrap();
    };
    let property = |name: &str| {
        call(
            &owner,
            "/StatusNotifierItem",
            "org.freedesktop.DBus.Properties.Get",
            &["org.kde.StatusNotifierItem", name],
        )
        .unwrap()
    };
    let layout = menu();
    for item in [
        "Force Default Layout",
        "Pause Auto-Switching",
        "Always Use",
        "Forget Learned Layout",
        "Remove All Pins",
        "Launch at Login",
    ] {
        assert!(layout.contains(item), "menu lacks {item}");
    }
    // Enlightenment opens the menu only when the root declares a submenu.
    assert!(
        layout.contains("(0, {'children-display': <'submenu'>"),
        "menu root is not a submenu"
    );
    assert!(property("IconName").contains("'insomemo-symbolic'"));
    let icons = property("IconThemePath");
    let icons = Path::new(icons.split('\'').nth(1).unwrap());
    for name in [
        "insomemo-symbolic",
        "insomemo-top-right-symbolic",
        "insomemo-dark-symbolic",
    ] {
        assert!(icons.join(format!("{name}.svg")).exists(), "{name}");
    }

    click("2");
    assert!(menu().contains("Resume Auto-Switching"));
    click("100");
    let state_path = dir.join("state.json");
    let clicked = Instant::now();
    assert!(
        !state_path.exists(),
        "Save must be debounced, not immediate"
    );
    // The 2 s debounce plus fsync can overrun a fixed sleep on busy CI runners.
    while !state_path.exists() {
        assert!(
            clicked.elapsed() < Duration::from_secs(10),
            "Debounced save did not happen"
        );
        sleep(Duration::from_millis(100));
    }
    assert!(
        clicked.elapsed() >= Duration::from_millis(1900),
        "Save happened before the debounce"
    );
    assert_eq!(read_state(&dir)["default_layout"], layouts[0]["id"]);

    click("4");
    unsafe { libc::kill(daemon.0.id() as libc::pid_t, libc::SIGTERM) };
    let status = daemon.0.wait().unwrap();
    assert!(status.success(), "daemon exited with {status}");
    let state = read_state(&dir);
    assert_eq!(state["entries"], serde_json::json!({}));
    assert!(state["default_layout"].is_null());
    std::fs::remove_dir_all(&dir).unwrap();
}
