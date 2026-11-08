#!/usr/bin/env python3
"""Run under dbus-run-session + xvfb-run; verifies real tray RPC and clean exit."""
import json
import os
import pathlib
import subprocess
import tempfile
import time

root = pathlib.Path(__file__).resolve().parent.parent
binary = str(root / "target/release/insomemo")
environment = dict(os.environ)
for key in ("WAYLAND_DISPLAY", "SWAYSOCK", "HYPRLAND_INSTANCE_SIGNATURE"):
    environment.pop(key, None)
environment["XDG_SESSION_TYPE"] = "x11"

def call(destination, path, method, *arguments):
    return subprocess.check_output([
        "gdbus", "call", "--session", "--dest", destination,
        "--object-path", path, "--method", method, "--", *arguments,
    ], text=True, env=environment, stderr=subprocess.DEVNULL)

with tempfile.TemporaryDirectory(prefix="insomemo-linux-") as directory:
    layouts = json.loads(subprocess.check_output([binary, "--list-layouts"], env=environment))
    assert layouts, "XKB must expose at least one layout"
    daemon = subprocess.Popen([binary, "--state-dir", directory], env=environment)
    try:
        # Bounded readiness retry in the test harness; the daemon has no polling.
        owner = None
        for _ in range(30):
            assert daemon.poll() is None, "Daemon exited during initialization"
            names = call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus.ListNames")
            import re
            for name in re.findall(r"':\d+\.\d+'", names):
                name = name.strip("'")
                try:
                    result = call(name, "/StatusNotifierItem", "org.freedesktop.DBus.Properties.Get", "org.kde.StatusNotifierItem", "Id")
                    if "insomemo" in result:
                        owner = name
                        break
                except subprocess.CalledProcessError:
                    pass
            if owner:
                break
            time.sleep(0.1)
        assert owner, "StatusNotifierItem was not registered"
        menu = call(owner, "/MenuBar", "com.canonical.dbusmenu.GetLayout", "0", "-1", "[]")
        assert "Force Default Layout" in menu and "Pause Auto-Switching" in menu
        assert "Always Use" in menu and "Forget Learned Layout" in menu and "Remove All Pins" in menu and "Show Switch Indicator" in menu
        call(owner, "/MenuBar", "com.canonical.dbusmenu.Event", "2", "clicked", "<0>", "0")
        assert "Resume Auto-Switching" in call(owner, "/MenuBar", "com.canonical.dbusmenu.GetLayout", "0", "-1", "[]")
        call(owner, "/MenuBar", "com.canonical.dbusmenu.Event", "100", "clicked", "<0>", "0")
        state_path = pathlib.Path(directory) / "state.json"
        clicked = time.monotonic()
        assert not state_path.exists(), "Save must be debounced, not immediate"
        # The 2 s debounce plus fsync can overrun a fixed sleep on busy CI runners.
        while not state_path.exists():
            assert time.monotonic() - clicked < 10, "Debounced save did not happen"
            time.sleep(0.1)
        assert time.monotonic() - clicked >= 1.9, "Save happened before the debounce"
        state = json.loads(state_path.read_text())
        assert state["default_layout"] == layouts[0]["id"]
        call(owner, "/MenuBar", "com.canonical.dbusmenu.Event", "4", "clicked", "<0>", "0")
        daemon.terminate()
        assert daemon.wait(timeout=5) == 0
        state = json.loads((pathlib.Path(directory) / "state.json").read_text())
        assert state["entries"] == {} and state["default_layout"] is None
        print("X11 startup, tray menu, pause, default, debounce, clear, and shutdown passed")
    finally:
        if daemon.poll() is None:
            daemon.kill()
            daemon.wait()
