#!/bin/sh
# Bundle, sign, notarize, and package Insomemo for distribution.
# Usage: package-macos.sh BINARY OUTPUT_PREFIX
#   Writes OUTPUT_PREFIX.zip and OUTPUT_PREFIX.dmg.
#
# Without CODESIGN_IDENTITY the app is ad-hoc signed and nothing is notarized.
# With it ("Developer ID Application: Name (TEAMID)"), the app and disk image
# are signed with the hardened runtime and notarized, using either
#   NOTARY_PROFILE  a keychain profile from `xcrun notarytool store-credentials`, or
#   APPLE_API_KEY_PATH, APPLE_API_KEY_ID, APPLE_API_ISSUER  an App Store Connect API key.
set -eu
binary=${1:?usage: package-macos.sh BINARY OUTPUT_PREFIX}
prefix=${2:?usage: package-macos.sh BINARY OUTPUT_PREFIX}
root=$(cd "$(dirname "$0")/.." && pwd)
app="$root/dist/Insomemo.app"
identity=${CODESIGN_IDENTITY:--}

notarize() {
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        set -- "$1" --keychain-profile "$NOTARY_PROFILE"
    else
        set -- "$1" --key "${APPLE_API_KEY_PATH:?set NOTARY_PROFILE or an API key}" \
            --key-id "${APPLE_API_KEY_ID:?}" --issuer "${APPLE_API_ISSUER:?}"
    fi
    xcrun notarytool submit "$@" --wait --timeout 30m
}

python3 "$root/scripts/bundle-macos.py" "$binary"
if [ "$identity" != "-" ]; then
    # Notarize the app itself and staple its ticket, so a copy taken out of the
    # disk image or zip still opens offline.
    submission=$(mktemp -d)/Insomemo.zip
    ditto -c -k --keepParent "$app" "$submission"
    notarize "$submission"
    xcrun stapler staple "$app"
fi
ditto -c -k --keepParent "$app" "$prefix.zip"
"$root/scripts/make-dmg.sh" "$prefix.dmg"
if [ "$identity" != "-" ]; then
    notarize "$prefix.dmg"
    xcrun stapler staple "$prefix.dmg"
    spctl --assess --type open --context context:primary-signature --verbose "$prefix.dmg"
    spctl --assess --type execute --verbose "$app"
fi
