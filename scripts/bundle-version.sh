#!/bin/sh
# Print the app's CFBundleVersion, which Sparkle compares, for a Cargo.toml
# version. Sparkle reads 0.3.0-rc.2 as 0.3.0, so the suffix loses its
# separators: 0.3.0rc2 comes before 0.3.0, and rc9 before rc10.
# Usage: bundle-version.sh VERSION
set -eu
version=${1:?usage: bundle-version.sh VERSION}
case "$version" in
*-*) printf '%s%s\n' "${version%%-*}" "$(printf '%s' "${version#*-}" | tr -d .-)" ;;
*) printf '%s\n' "$version" ;;
esac
