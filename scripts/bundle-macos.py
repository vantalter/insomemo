#!/usr/bin/env python3
"""Package the built binary at a stable path for macOS Accessibility grants.

Usage: bundle-macos.py [BINARY]  (default: target/release/insomemo)
"""
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

if sys.platform != "darwin":
    raise SystemExit("App bundles can only be created on macOS")
root = pathlib.Path(__file__).resolve().parent.parent
binary = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / "target/release/insomemo"
manifest = (root / "Cargo.toml").read_text()
version = re.search(r'^version = "([^"]+)"', manifest, re.MULTILINE).group(1)
bundle = root / "dist" / "Insomemo.app"
contents = bundle / "Contents"
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
(contents / "Resources").mkdir(parents=True, exist_ok=True)
shutil.copy2(binary, contents / "MacOS/insomemo")
with tempfile.TemporaryDirectory(prefix="insomemo-icons-") as directory:
    iconset = pathlib.Path(directory) / "AppIcon.iconset"
    iconset.mkdir()
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            suffix = "@2x" if scale == 2 else ""
            subprocess.run([
                "sips", "-z", str(pixels), str(pixels), str(root / "assets/AppIcon.png"),
                "--out", str(iconset / f"icon_{points}x{points}{suffix}.png"),
            ], check=True, stdout=subprocess.DEVNULL)
    # iconutil stores the 16- and 32-pixel sizes in the formats every part of
    # macOS reads. Hand-assembled PNG "icp4"/"icp5" entries showed as noise in
    # System Settings' privacy lists.
    subprocess.run(["iconutil", "-c", "icns", str(iconset),
                    "-o", str(contents / "Resources/AppIcon.icns")], check=True)
with (contents / "Info.plist").open("wb") as output:
    plistlib.dump({
        "CFBundleName": "Insomemo",
        "CFBundleDisplayName": "Insomemo",
        "CFBundleIdentifier": "dev.insomemo.app",
        "CFBundleExecutable": "insomemo",
        "CFBundleIconFile": "AppIcon",
        "LSApplicationCategoryType": "public.app-category.utilities",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "12.0",
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
    }, output)
def development_identity():
    """An installed Apple Development certificate, if any.

    Ad-hoc signatures identify the app by a hash of each build, so macOS treats
    every rebuild as a new app and its Accessibility grant stops applying. A
    certificate gives every local build the same identity.
    """
    listing = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                             capture_output=True, text=True).stdout
    match = re.search(r'"(Apple Development: [^"]+)"', listing)
    return match.group(1) if match else None


# An explicit CODESIGN_IDENTITY wins, including "-" for ad-hoc.
identity = os.environ.get("CODESIGN_IDENTITY") or development_identity() or "-"
signing = ["codesign", "--force", "--sign", identity]
if identity.startswith("Developer ID"):
    # Developer ID distribution requires the hardened runtime and a secure timestamp.
    signing += ["--options", "runtime", "--timestamp"]
subprocess.run(signing + [str(bundle)], check=True)
print(f"signed with {identity if identity != '-' else 'ad-hoc signature'}")
print(bundle)
