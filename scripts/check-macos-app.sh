#!/bin/sh
# Check a built Insomemo.app: version, Sparkle settings, embedded framework,
# and signatures. Run by CI after build-macos-app.sh.
# Usage: check-macos-app.sh [APP]  (default: dist/Insomemo.app)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
app=${1:-$root/dist/Insomemo.app}
plist="$app/Contents/Info.plist"
failed=0
fail() {
    echo "error: $*" >&2
    failed=1
}
value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true
}

version=$(sed -n 's/^version = "\(.*\)"/\1/p' "$root/Cargo.toml" | head -1)
# Both follow Cargo.toml; CFBundleVersion, which Sparkle compares, in the form
# bundle-version.sh gives it.
[ "$(value CFBundleShortVersionString)" = "$version" ] ||
    fail "CFBundleShortVersionString is '$(value CFBundleShortVersionString)', expected $version"
bundle=$("$root/scripts/bundle-version.sh" "$version")
[ "$(value CFBundleVersion)" = "$bundle" ] || fail "CFBundleVersion is '$(value CFBundleVersion)', expected $bundle"
# Info.plist is preprocessed, where an unguarded "//" would start a comment.
feed=https://github.com/vantalter/insomemo/releases/latest/download/appcast.xml
[ "$(value SUFeedURL)" = "$feed" ] || fail "SUFeedURL is '$(value SUFeedURL)'"
key=$(value SUPublicEDKey)
[ -n "$key" ] && [ "$key" = "$(cat "$root/macos/sparkle-public-key")" ] ||
    fail "SUPublicEDKey does not match macos/sparkle-public-key"
[ "$(value SUEnableAutomaticChecks)" = false ] || fail "SUEnableAutomaticChecks is not false"

sparkle="$app/Contents/Frameworks/Sparkle.framework"
[ -f "$sparkle/Versions/B/Sparkle" ] || fail "Sparkle.framework is not embedded"
[ ! -e "$sparkle/Versions/B/XPCServices" ] || fail "Sparkle's XPC services were not removed"
otool -L "$app/Contents/MacOS/insomemo" | grep -q '@rpath/Sparkle.framework' ||
    fail "the executable does not link Sparkle"
otool -l "$app/Contents/MacOS/insomemo" | grep -q '@executable_path/../Frameworks' ||
    fail "the executable cannot find embedded frameworks"
codesign --verify --deep --strict "$app" || fail "the app's signatures do not verify"

[ "$failed" = 0 ] && echo "$app: version $version, Sparkle, and signatures OK"
exit "$failed"
