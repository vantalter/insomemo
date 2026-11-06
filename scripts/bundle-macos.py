#!/usr/bin/env python3
"""Package the built binary at a stable path for macOS Accessibility grants."""
import pathlib
import plistlib
import shutil
import subprocess
import sys

if sys.platform != "darwin":
    raise SystemExit("App bundles can only be created on macOS")
root = pathlib.Path(__file__).resolve().parent.parent
bundle = root / "dist" / "Input Switcher.app"
contents = bundle / "Contents"
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
shutil.copy2(root / "target/release/input-switcher", contents / "MacOS/input-switcher")
with (contents / "Info.plist").open("wb") as output:
    plistlib.dump({
        "CFBundleName": "Input Switcher",
        "CFBundleDisplayName": "Input Switcher",
        "CFBundleIdentifier": "dev.input-switcher.app",
        "CFBundleExecutable": "input-switcher",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "12.0",
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
    }, output)
subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True)
print(bundle)
