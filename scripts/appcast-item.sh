#!/bin/bash
# Writes an update's <item> for Axo's appcast (#180) to stdout: its version and build, the
# minimum macOS, the channel, plain-text release notes, and the DMG's address with the EdDSA
# signature attributes sign_update printed. scripts/package-release.sh runs it;
# scripts/tests/test_appcast_item.sh checks it.
#
#   appcast-item.sh <version> <build> <minimum-macOS> <download-url> <signature-attributes> [beta] [notes-file]
set -euo pipefail

[[ $# -ge 5 ]] || { echo "usage: appcast-item.sh <version> <build> <minimum-macOS> <download-url> <signature-attributes> [beta] [notes-file]" >&2; exit 2; }
VERSION="$1" BUILD="$2" MINIMUM_SYSTEM="$3" DOWNLOAD_URL="$4" SIGNATURE="$5" CHANNEL="${6:-}" NOTES="${7:-}"
# sign_update prints exactly these two attributes; anything else would go into the XML as is.
[[ "$SIGNATURE" =~ ^sparkle:edSignature=\"[A-Za-z0-9+/=]+\"\ length=\"[0-9]+\"$ ]] \
  || { echo "error: unexpected signature attributes: $SIGNATURE" >&2; exit 1; }

xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

echo "<item>"
echo "  <title>Axo $(printf '%s' "$VERSION" | xml_escape)</title>"
echo "  <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>"
echo "  <sparkle:version>$(printf '%s' "$BUILD" | xml_escape)</sparkle:version>"
echo "  <sparkle:shortVersionString>$(printf '%s' "$VERSION" | xml_escape)</sparkle:shortVersionString>"
echo "  <sparkle:minimumSystemVersion>$(printf '%s' "$MINIMUM_SYSTEM" | xml_escape)</sparkle:minimumSystemVersion>"
if [[ "$CHANNEL" == beta ]]; then echo "  <sparkle:channel>beta</sparkle:channel>"; fi
if [[ -n "$NOTES" ]]; then
  # Sparkle reads the format from sparkle:format; without it, notes count as HTML.
  echo "  <description sparkle:format=\"plain-text\">$(xml_escape < "$NOTES")</description>"
fi
echo "  <enclosure url=\"$(printf '%s' "$DOWNLOAD_URL" | xml_escape)\" $SIGNATURE type=\"application/octet-stream\"/>"
echo "</item>"
