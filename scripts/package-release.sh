#!/bin/bash
# Builds Axo's Release DMG for the Mac (#61): archives Release with the Chromium engine embedded,
# exports it signed with your Developer ID, checks the engine's signing, notarizes and staples
# the app, puts it in a DMG, signs, notarizes, and staples that, signs the DMG for Sparkle and
# writes its appcast item (#180), and writes a manifest naming the engine build it carries. See
# docs/releasing.md for the one-time setup.
#
#   scripts/package-release.sh [--skip-notarize] [--allow-dirty] [--beta] [--notes <file>]
#
# Nothing secret is read from the repo: signing uses your keychain's Developer ID identity
# through Xcode, and notarization the notarytool keychain profile named by AXO_NOTARY_PROFILE
# (default "axo-notary", made once with `xcrun notarytool store-credentials`).
#
# --skip-notarize builds and signs everything but skips notarizing and stapling: a DMG to try on
#   this Mac, never to publish (macOS refuses it on any other).
# --allow-dirty packages with uncommitted changes in Axo or the engine: also never to publish,
#   since the manifest couldn't name what the DMG was built from.
# --beta puts the update on the appcast's beta channel, offered only to people who include betas.
# --notes <file> is the update's release notes, as plain text, for the appcast item.
#
# The update's EdDSA signature uses the Sparkle private key in your keychain (made once with
# Sparkle's generate_keys); its public half is the Axo target's AXO_SPARKLE_PUBLIC_KEY.
#
# The DMG, its manifest, and the build's logs go in AXO_RELEASE_DIR (default build/release, which
# git ignores).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOTARIZE=1
ALLOW_DIRTY=0
BETA=0
NOTES=""
usage() { echo "usage: package-release.sh [--skip-notarize] [--allow-dirty] [--beta] [--notes <file>]"; exit 2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-notarize) NOTARIZE=0 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --beta) BETA=1 ;;
    --notes) [[ $# -ge 2 ]] || usage; NOTES="$2"; shift ;;
    *) usage ;;
  esac
  shift
done
PROFILE="${AXO_NOTARY_PROFILE:-axo-notary}"
RELEASE_DIR="${AXO_RELEASE_DIR:-$ROOT/build/release}"
WORK="$RELEASE_DIR/work"
step() { echo; echo "==> $*"; }
die() { echo "error: $*" >&2; exit 1; }

# MARK: Where the engine comes from

# The same engine the embed phase finds (scripts/embed-chromium-engine.sh): AXO_CHROMIUM_OUT, or
# the axo-chromium checkout beside Axo (beside the main checkout when this is a git worktree).
OUT="${AXO_CHROMIUM_OUT:-$ROOT/../axo-chromium/chromium/src/out/Axo}"
if [[ -z "${AXO_CHROMIUM_OUT:-}" && ! -d "$OUT" ]]; then
  COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
  OUT="$(dirname "$(dirname "$COMMON")")/axo-chromium/chromium/src/out/Axo"
fi
ENGINE_BINARY="$OUT/Chromium.app/Contents/Frameworks/Chromium Framework.framework/Versions/Current/Chromium Framework"
[[ -f "$ENGINE_BINARY" ]] || die "No Chromium engine at $OUT. Build axo-chromium first (or set AXO_CHROMIUM_OUT)."
FORK="$(cd "$OUT/../../../.." && pwd)"
git -C "$FORK" rev-parse --git-dir > /dev/null 2>&1 || die "$FORK isn't the axo-chromium checkout the engine was built from."

# MARK: Preflight

step "Checking what's being packaged"
[[ -z "$NOTES" || -f "$NOTES" ]] || die "No release notes at $NOTES."
for tool in xcodebuild codesign hdiutil ditto shasum; do
  command -v "$tool" > /dev/null || die "$tool is missing."
done
AXO_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
# The fork's own files only: chromium/src is Chromium's checkout (gitignored in the fork), which
# the fork's patches change, so edits made there directly aren't seen.
ENGINE_COMMIT="$(git -C "$FORK" rev-parse HEAD)"
if [[ "$ALLOW_DIRTY" == 0 ]]; then
  [[ -z "$(git -C "$ROOT" status --porcelain)" ]] || die "Axo has uncommitted changes. Commit them, or pass --allow-dirty for a DMG you won't publish."
  [[ -z "$(git -C "$FORK" status --porcelain)" ]] || die "The engine checkout ($FORK) has uncommitted changes. Commit them and rebuild, or pass --allow-dirty for a DMG you won't publish."
fi
cmp -s "$FORK/axo/public/AxoEngineProtocols.h" "$ROOT/Packages/AxoChromium/Sources/AxoEngineAPI/include/AxoEngineProtocols.h" \
  || die "Axo's engine API header differs from the engine's. Use the engine build that matches this Axo."
# A build older than the newest change to the fork's code carries something else. This can't
# catch every mismatch (checking out an older commit after building a newer one passes), so build
# the engine from the commit you're releasing; the manifest names the checkout's commit.
NEWEST_CHANGE="$(git -C "$FORK" log -1 --format=%ct -- axo patches)"
[[ "$(stat -f %m "$ENGINE_BINARY")" -ge "$NEWEST_CHANGE" ]] \
  || die "The engine build at $OUT is older than the engine checkout's last change. Rebuild it."
# Hashed now, so a rebuild during the run can't change what the manifest names.
ENGINE_SHA="$(shasum -a 256 "$ENGINE_BINARY" | cut -d' ' -f1)"
CHROMIUM_VERSION="$(cat "$FORK/CHROMIUM_VERSION" 2>/dev/null || echo unknown)"
if [[ "$NOTARIZE" == 1 ]]; then
  xcrun notarytool history --keychain-profile "$PROFILE" > /dev/null 2>&1 \
    || die "No notarytool keychain profile named \"$PROFILE\". Make one with: xcrun notarytool store-credentials \"$PROFILE\" (docs/releasing.md)."
fi

rm -rf "$WORK"
mkdir -p "$WORK"
ARCHIVE="$WORK/Axo.xcarchive"
EXPORT="$WORK/export"
APP="$EXPORT/Axo.app"

# MARK: Build and sign

step "Archiving Release (the engine is embedded and signed by the build)"
xcodebuild archive \
  -workspace "$ROOT/Axo.xcworkspace" -scheme Axo -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  -clonedSourcePackagesDirPath "$WORK/packages" \
  -allowProvisioningUpdates AXO_CHROMIUM_OUT="$OUT" \
  > "$RELEASE_DIR/archive.log" 2>&1 \
  || { grep -E 'error:' "$RELEASE_DIR/archive.log" | head -20 || true; die "The archive failed; see $RELEASE_DIR/archive.log."; }

step "Exporting with your Developer ID"
TEAM="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:Team' "$ARCHIVE/Info.plist" 2>/dev/null \
  || codesign -d --verbose=2 "$ARCHIVE/Products/Applications/Axo.app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ -n "$TEAM" ]] || die "Couldn't read the archive's team."
cat > "$WORK/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$TEAM</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" -allowProvisioningUpdates \
  > "$RELEASE_DIR/export.log" 2>&1 \
  || { grep -E 'error' "$RELEASE_DIR/export.log" | head -20 || true; die "The export failed; see $RELEASE_DIR/export.log."; }

step "Checking the engine's signing"
"$ROOT/scripts/verify-engine-signing.sh" "$APP" --release

# Sparkle's tools come with the Sparkle package the archive resolved.
SPARKLE_BIN="$WORK/packages/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE_BIN/sign_update" ]] || die "Sparkle's tools aren't at $SPARKLE_BIN."
# Updates are signed with the private key in your keychain; the app checks them with the public
# key it carries. If they don't match, every update would be refused, so check before going on.
APP_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ -n "$APP_KEY" ]] || die "Axo has no SUPublicEDKey: set the Axo target's AXO_SPARKLE_PUBLIC_KEY (docs/releasing.md)."
KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null || true)"
[[ -n "$KEYCHAIN_KEY" ]] || die "No Sparkle signing key in your keychain. Make one with $SPARKLE_BIN/generate_keys (docs/releasing.md)."
[[ "$APP_KEY" == "$KEYCHAIN_KEY" ]] || die "AXO_SPARKLE_PUBLIC_KEY isn't the public half of the Sparkle key in your keychain."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
NAME="Axo-$VERSION-$BUILD"
IDENTITY="$(codesign -d --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
# The DMG is signed with the very certificate that signed the app, by its SHA-1 fingerprint: a
# name can match both a renewed certificate and the expired one it replaced.
( cd "$WORK" && codesign -d --extract-certificates "$APP" 2>/dev/null )
CERTIFICATE="$(shasum -a 1 "$WORK/codesign0" | cut -d' ' -f1 | tr a-f A-F)"

# Submits a file to Apple's notary service, waits for it, and prints Apple's log if it's refused.
notarize() {
  local file="$1" result id status
  # notarytool exits non-zero for a refused submission; read its answer anyway, for the log.
  result="$(xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format plist)" || true
  [[ -n "$result" ]] || die "Couldn't submit $(basename "$file") for notarization."
  id="$(/usr/libexec/PlistBuddy -c 'Print :id' /dev/stdin <<<"$result")"
  status="$(/usr/libexec/PlistBuddy -c 'Print :status' /dev/stdin <<<"$result")"
  if [[ "$status" != "Accepted" ]]; then
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" || true
    die "Notarizing $(basename "$file") ended \"$status\" (submission $id)."
  fi
}

# The app is notarized and stapled on its own first, so it opens offline once copied out of the
# DMG; the DMG is then notarized too, so opening it passes Gatekeeper.
if [[ "$NOTARIZE" == 1 ]]; then
  step "Notarizing Axo.app (this takes a few minutes)"
  ditto -c -k --keepParent "$APP" "$WORK/Axo.zip"
  notarize "$WORK/Axo.zip"
  xcrun stapler staple "$APP"
fi

step "Making the DMG"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Axo.app"
ln -s /Applications "$STAGE/Applications"
DMG="$RELEASE_DIR/$NAME.dmg"
rm -f "$DMG"
hdiutil create -volname "Axo" -srcfolder "$STAGE" -fs HFS+ -format ULFO "$DMG" > /dev/null
codesign --sign "$CERTIFICATE" --timestamp "$DMG"

if [[ "$NOTARIZE" == 1 ]]; then
  step "Notarizing the DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

# MARK: The appcast item

# The update's entry for the appcast on GitHub Pages: its version, its release notes, and the DMG
# on GitHub Releases with its EdDSA signature. Publishing adds it to appcast.xml (docs/releasing.md).
step "Signing the update for Sparkle"
SIGNATURE="$("$SPARKLE_BIN/sign_update" "$DMG")" || die "Couldn't sign the DMG for Sparkle."
DOWNLOAD_URL="${AXO_RELEASE_DOWNLOAD_URL:-https://github.com/perezstudio/axo-browser/releases/download/v$VERSION}/$NAME.dmg"
MINIMUM_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
{
  echo "<item>"
  echo "  <title>Axo $VERSION</title>"
  echo "  <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>"
  echo "  <sparkle:version>$BUILD</sparkle:version>"
  echo "  <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>"
  echo "  <sparkle:minimumSystemVersion>$MINIMUM_SYSTEM</sparkle:minimumSystemVersion>"
  if [[ "$BETA" == 1 ]]; then echo "  <sparkle:channel>beta</sparkle:channel>"; fi
  if [[ -n "$NOTES" ]]; then
    echo "  <description sparkle:descriptionFormat=\"plain-text\">$(xml_escape < "$NOTES")</description>"
  fi
  echo "  <enclosure url=\"$(printf '%s' "$DOWNLOAD_URL" | xml_escape)\" $SIGNATURE type=\"application/octet-stream\"/>"
  echo "</item>"
} > "$RELEASE_DIR/$NAME.appcast-item.xml"

# MARK: The manifest

# Each release names the engine build it carries: the fork's commit, the Chromium it's based on,
# and the engine binary's checksum, so a release can be traced to (and rebuilt from) its engine.
step "Writing the manifest"
cat > "$RELEASE_DIR/$NAME.txt" <<EOF
Axo $VERSION ($BUILD)
Axo commit: $AXO_COMMIT
Engine commit (axo-chromium): $ENGINE_COMMIT
Chromium: $CHROMIUM_VERSION
Engine binary SHA-256: $ENGINE_SHA
DMG SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)
Signed by: $IDENTITY
Notarized: $([[ "$NOTARIZE" == 1 ]] && echo yes || echo "no (not for publishing)")
Uncommitted changes allowed: $([[ "$ALLOW_DIRTY" == 1 ]] && echo "yes (not for publishing)" || echo no)
Channel: $([[ "$BETA" == 1 ]] && echo beta || echo release)
Appcast item: $NAME.appcast-item.xml
Built: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
cat "$RELEASE_DIR/$NAME.txt"
echo
echo "Done: $DMG"
