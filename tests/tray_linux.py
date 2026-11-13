#!/usr/bin/env python3
"""Exercise late/restarted tray hosts and Cinnamon's PNG + SNI pixel paths.
Run: dbus-run-session -- xvfb-run -a python3 tests/tray_linux.py BINARY
Requires python3-gi and gir1.2-gdkpixbuf-2.0, only for this test.
"""
import json
import os
import shlex
from pathlib import Path
import subprocess
import sys
import tempfile
import time

import gi

gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gio, GLib, GdkPixbuf

WATCHER = "org.kde.StatusNotifierWatcher"
ITEM = "org.kde.StatusNotifierItem"
PROPS = "org.freedesktop.DBus.Properties"
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
registrations = []


def registered(connection, sender, path, interface, method, parameters, invocation):
    registrations.append((sender, parameters.unpack()[0]))
    invocation.return_value(None)


info = Gio.DBusNodeInfo.new_for_xml("""<node>
<interface name="org.kde.StatusNotifierWatcher">
<method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
</interface></node>""")
bus.register_object("/StatusNotifierWatcher", info.interfaces[0], registered, None, None)


def call(destination, path, interface, method, parameters=None):
    return bus.call_sync(destination, path, interface, method, parameters, None,
                         Gio.DBusCallFlags.NONE, 3000, None).unpack()


def own(method):
    signature, args = ("(su)", (WATCHER, 0)) if method == "RequestName" else ("(s)", (WATCHER,))
    result = call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                  "org.freedesktop.DBus", method, GLib.Variant(signature, args))
    assert result == (1,), result


def wait_for(predicate, process):
    deadline = time.monotonic() + 5
    while not predicate():
        assert process.poll() is None, "daemon exited"
        assert time.monotonic() < deadline, "timed out waiting for tray update"
        GLib.MainContext.default().iteration(False)
        time.sleep(.01)


def pixels(properties):
    path = Path(properties["IconName"])
    assert path.is_absolute() and path.suffix == ".png", path
    image = GdkPixbuf.Pixbuf.new_from_file(str(path))
    width, height, wire = properties["IconPixmap"][0]
    assert (width, height) == (image.get_width(), image.get_height())
    assert len(wire) == width * height * 4
    rgba = image.get_pixels()
    stride = image.get_rowstride()
    for y in range(height):
        for x in range(width):
            i, j = y * stride + x * 4, (y * width + x) * 4
            r, g, b, a = rgba[i:i + 4]
            assert tuple(wire[j:j + 4]) == (a, r, g, b), "incorrect SNI ARGB byte order"
    alpha = wire[::4]
    assert min(alpha) == 0 and max(alpha) == 255, "invisible or opaque rectangular icon"
    return bytes(wire)


with tempfile.TemporaryDirectory(prefix="insomemo-tray-") as directory:
    root = Path(__file__).resolve().parent.parent
    data = (root / "assets/TrayTemplate.png").read_bytes()
    Path(directory, "tray_icon.h").write_text(
        "static const unsigned char tray_icon[] = {" + ",".join(map(str, data)) + "};\n")
    flags = subprocess.check_output([
        "pkg-config", "--cflags", "--libs", "gio-unix-2.0", "x11",
        "json-glib-1.0", "xkbcommon", "gdk-pixbuf-2.0"], text=True)
    executable = str(Path(directory, "icon-tests"))
    subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                    str(root / "tests/linux_icons.c"), str(root / "native/linux_icon.c"),
                    "-I" + directory, "-o", executable, *shlex.split(flags)], check=True)
    subprocess.run([executable, directory], check=True)
    fake_curl = Path(directory, "curl")
    fake_curl.write_text("#!/usr/bin/python3\nprint(" + repr(json.dumps([
        {"tag_name": "v0.2.10", "prerelease": True}
    ])) + ")\n")
    fake_curl.chmod(0o755)
    env = os.environ.copy()
    env["PATH"] = directory + os.pathsep + env["PATH"]
    for key in ("WAYLAND_DISPLAY", "SWAYSOCK", "HYPRLAND_INSTANCE_SIGNATURE"):
        env.pop(key, None)
    env.update(XDG_SESSION_TYPE="x11", XDG_CURRENT_DESKTOP="X-Cinnamon",
               XDG_RUNTIME_DIR=directory)
    process = subprocess.Popen([sys.argv[1], "--state-dir", directory + "/state"], env=env)
    try:
        # Start the daemon before a tray host exists, as at desktop login.
        wait_for(lambda: Path(directory, "insomemo/icons/insomemo-symbolic.svg").exists(), process)
        own("RequestName")
        wait_for(lambda: len(registrations) == 1, process)
        owner, path = registrations[0]
        assert path == "/StatusNotifierItem", path

        def properties():
            return call(owner, path, PROPS, "GetAll", GLib.Variant("(s)", (ITEM,)))[0]

        initial = properties()
        assert initial["Status"] == "Active"
        normal = pixels(initial)
        def menu():
            return str(call(owner, "/MenuBar", "com.canonical.dbusmenu", "GetLayout",
                            GLib.Variant("(iias)", (0, -1, []))))

        def click(item):
            call(owner, "/MenuBar", "com.canonical.dbusmenu", "Event",
                 GLib.Variant("(isvu)", (item, "clicked", GLib.Variant("i", 0), 0)))

        assert "Check for Updates" in menu()
        assert "Automatically Check for Updates" in menu()
        click(12)
        wait_for(lambda: "Version v0.2.10 available" in menu(), process)
        click(13)
        state_file = Path(directory, "state/state.json")
        wait_for(lambda: state_file.exists() and
                 json.loads(state_file.read_text()).get("auto_check_updates") is True, process)

        click(2)
        paused = properties()
        assert paused["Title"] == "Insomemo (Paused)"
        assert pixels(paused) != normal, "pause did not change the fallback icon"
        own("ReleaseName")
        # Both ownership changes must reach the daemon, even if queued together.
        own("RequestName")
        wait_for(lambda: len(registrations) == 2, process)
        assert registrations[1] == registrations[0]
        assert pixels(properties()) == pixels(paused)
        print("PASS: tray pixels, update menu, saved automatic preference, pause and host restart")
    finally:
        process.terminate()
        process.wait(timeout=5)
