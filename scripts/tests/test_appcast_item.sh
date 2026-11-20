#!/bin/bash
# Checks scripts/appcast-item.sh (#180): the item is well-formed XML inside an appcast, escapes
# the notes and address, marks the notes plain text the way Sparkle reads it (sparkle:format),
# puts betas on the beta channel, and refuses signature attributes sign_update wouldn't print.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILURES=0
fail() { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }
SIGNATURE='sparkle:edSignature="abc+/123==" length="4096"'

printf 'New\n• Fixed x < y & "z" > w\n' > "$WORK/notes.txt"
"$ROOT/scripts/appcast-item.sh" 1.1 42 27.0 "https://example.com/d?a=1&b=2" "$SIGNATURE" beta "$WORK/notes.txt" > "$WORK/item.xml"
{
  echo '<?xml version="1.0" encoding="utf-8"?>'
  echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>'
  cat "$WORK/item.xml"
  echo '</channel></rss>'
} > "$WORK/appcast.xml"
xmllint --noout "$WORK/appcast.xml" 2>/dev/null || fail "the appcast isn't well-formed XML"

value() { xmllint --xpath "$1" "$WORK/appcast.xml" 2>/dev/null || true; }
NS='/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"]'
[[ "$(value "string($NS/*[local-name()='description']/@*[local-name()='format'])")" == plain-text ]] \
  || fail "the notes aren't marked sparkle:format=\"plain-text\""
[[ "$(value "string($NS/*[local-name()='description'])")" == $'New\n• Fixed x < y & "z" > w' ]] \
  || fail "the notes didn't come back as written: $(value "string($NS/*[local-name()='description'])")"
[[ "$(value "string($NS/*[local-name()='enclosure']/@url)")" == "https://example.com/d?a=1&b=2" ]] || fail "the address wasn't escaped"
[[ "$(value "string($NS/*[local-name()='enclosure']/@length)")" == 4096 ]] || fail "the length is missing"
[[ "$(value "string($NS/*[local-name()='channel'])")" == beta ]] || fail "a beta isn't on the beta channel"
[[ "$(value "string($NS/*[local-name()='version'])")" == 42 ]] || fail "the build isn't sparkle:version"

"$ROOT/scripts/appcast-item.sh" 1.1 42 27.0 https://example.com/d "$SIGNATURE" "" > "$WORK/release.xml"
grep -q "sparkle:channel" "$WORK/release.xml" && fail "a release went on a channel"
grep -q "<description" "$WORK/release.xml" && fail "notes appeared without a notes file"

if "$ROOT/scripts/appcast-item.sh" 1.1 42 27.0 https://example.com/d 'length="1" onload="x"' "" > /dev/null 2>&1; then
  fail "unexpected signature attributes were accepted"
fi

if [[ "$FAILURES" -gt 0 ]]; then echo "$FAILURES check(s) failed."; exit 1; fi
echo "The appcast item is what Sparkle reads."
