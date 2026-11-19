#!/bin/sh
# Write the Sparkle update feed for one release to stdout.
# Usage: SPARKLE_PRIVATE_KEY=... make-appcast.sh ARCHIVE VERSION
#
# The feed lists only this release: Sparkle needs only the newest one, and the
# app reads it from the latest GitHub release. The archive is signed with the
# private key whose public half is in macos/sparkle-public-key.
set -eu
archive=${1:?usage: make-appcast.sh ARCHIVE VERSION}
version=${2:?usage: make-appcast.sh ARCHIVE VERSION}
: "${SPARKLE_PRIVATE_KEY:?set SPARKLE_PRIVATE_KEY}"
root=$(cd "$(dirname "$0")/.." && pwd)
repository=https://github.com/vantalter/insomemo

# sign_update from the Sparkle release the Xcode project resolved.
resolved="$root/macos/Insomemo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
sparkle=$(sed -n 's/.*"version" : "\(.*\)".*/\1/p' "$resolved" | head -1)
tools=$(mktemp -d)
trap 'rm -rf "$tools"' EXIT
curl -sSfL "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle/Sparkle-$sparkle.tar.xz" |
    tar -xJf - -C "$tools" ./bin/sign_update
signature=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/bin/sign_update" --ed-key-file - "$archive")

# The update window lists the commits since the previous release.
previous=$("$root/scripts/previous-tag.sh" "$version")
# A merged pull request's own title is the first line of the message body.
notes=$(git -C "$root" log --no-merges --format=%H ${previous:+"$previous..HEAD"} |
    while read -r commit; do
        subject=$(git -C "$root" log -1 --format=%s "$commit")
        case "$subject" in
        ("Merge pull request "*) git -C "$root" log -1 --format=%b "$commit" | sed '/^$/d' | head -1 ;;
        (*) echo "$subject" ;;
        esac
    done |
    grep -v '^Release [0-9]' |
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's|.*|<li>&</li>|')

cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Insomemo</title>
    <link>$repository</link>
    <item>
      <title>Insomemo $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$version</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$repository/releases/tag/v$version</sparkle:fullReleaseNotesLink>
      <description><![CDATA[<ul>
$notes
</ul>]]></description>
      <enclosure url="$repository/releases/download/v$version/$(basename "$archive")" type="application/octet-stream" $signature/>
    </item>
  </channel>
</rss>
EOF
