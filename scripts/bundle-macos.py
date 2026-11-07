#!/usr/bin/env python3
"""Package the built binary at a stable path for macOS Accessibility grants.

Usage: bundle-macos.py [BINARY]  (default: target/release/insomemo)
"""
import pathlib
import plistlib
import re
import shutil
import struct
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
    # ICNS is a big-endian container of typed image representations. Assemble
    # the PNG representations directly so packaging does not depend on
    # iconutil's encoder, including in sandboxed/headless build environments.
    representations = (
        (b"icp4", "icon_16x16.png"), (b"ic11", "icon_16x16@2x.png"),
        (b"icp5", "icon_32x32.png"), (b"ic12", "icon_32x32@2x.png"),
        (b"ic07", "icon_128x128.png"), (b"ic13", "icon_128x128@2x.png"),
        (b"ic08", "icon_256x256.png"), (b"ic14", "icon_256x256@2x.png"),
        (b"ic09", "icon_512x512.png"), (b"ic10", "icon_512x512@2x.png"),
    )
    chunks = []
    for kind, filename in representations:
        png = (iconset / filename).read_bytes()
        chunks.append(kind + struct.pack(">I", len(png) + 8) + png)
    payload = b"".join(chunks)
    (contents / "Resources/AppIcon.icns").write_bytes(
        b"icns" + struct.pack(">I", len(payload) + 8) + payload
    )
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
subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True)
print(bundle)
