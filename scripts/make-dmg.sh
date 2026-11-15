#!/bin/sh
# Package dist/Insomemo.app as a drag-to-install disk image.
# Usage: make-dmg.sh OUTPUT.dmg
set -eu
output=${1:?usage: make-dmg.sh OUTPUT.dmg}
root=$(cd "$(dirname "$0")/.." && pwd)
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
# The Applications link lets people install by dragging the app onto it.
ditto "$root/dist/Insomemo.app" "$staging/Insomemo.app"
ln -s /Applications "$staging/Applications"
# ULFO (LZFSE) is Apple's compact read-only format, supported since macOS 10.11.
hdiutil create -volname Insomemo -srcfolder "$staging" -fs HFS+ -format ULFO -ov "$output"
# Sign the image too when distributing; notarization covers both.
if [ "${CODESIGN_IDENTITY:--}" != "-" ]; then
    codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$output"
fi
