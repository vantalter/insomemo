#!/bin/sh
# Build dist/Insomemo.app from the Xcode project and sign it.
# Usage: build-macos-app.sh [universal]
#   Builds for this Mac's architecture, or for arm64 and x86_64 with "universal".
#
# The identity is CODESIGN_IDENTITY when set ("-" for ad-hoc), otherwise an
# installed Apple Development certificate, otherwise ad-hoc. Ad-hoc signatures
# identify the app by a hash of each build, so macOS treats every rebuild as a
# new app and its Accessibility grant stops applying; a certificate gives every
# local build the same identity.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
build="$root/target/xcode"
app="$root/dist/Insomemo.app"
if [ "${1:-}" = universal ]; then
    set -- ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO
else
    set -- ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES
fi
# Signing happens below, so the same identity rules apply in CI and locally.
xcodebuild -quiet -project "$root/macos/Insomemo.xcodeproj" -target Insomemo \
    -configuration Release SYMROOT="$build" OBJROOT="$build/obj" \
    CODE_SIGNING_ALLOWED=NO "$@" build
rm -rf "$app"
mkdir -p "$root/dist"
ditto "$build/Release/Insomemo.app" "$app"

identity=${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}
identity=${identity:--}
if [ "${identity#Developer ID}" != "$identity" ]; then
    # Developer ID distribution requires the hardened runtime and a secure timestamp.
    codesign --force --sign "$identity" --options runtime --timestamp "$app"
else
    codesign --force --sign "$identity" "$app"
fi
if [ "$identity" = - ]; then echo "signed with ad-hoc signature"; else echo "signed with $identity"; fi
echo "$app"
