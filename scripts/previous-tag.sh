#!/bin/sh
# Print the tag of the release before the one being built from HEAD, or
# nothing for the first release. A final release such as 1.2.0 skips release
# candidates, so its notes cover everything since the previous final release.
# Usage: previous-tag.sh VERSION
set -eu
version=${1:?usage: previous-tag.sh VERSION}
root=$(cd "$(dirname "$0")/.." && pwd)
case "$version" in
*-*) exclude= ;;
*) exclude='*-*' ;;
esac
git -C "$root" describe --tags --abbrev=0 ${exclude:+--exclude "$exclude"} HEAD^ 2>/dev/null || true
