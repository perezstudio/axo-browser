#!/bin/bash
# Run by the Axo target's "Embed Chromium Engine" build phase. In Debug builds, copies the
# Chromium engine framework built by the axo-chromium fork into Axo.app/Contents/Frameworks and
# signs it with Axo's identity, so the "ChromiumEngine" debug setting can use it (see
# docs/chromium-engine.md). Without a built engine, Axo builds and runs on WebKit as usual.
#
# The engine comes from $AXO_CHROMIUM_OUT, or from a sibling checkout of axo-chromium:
#   ../axo-chromium/chromium/src/out/Axo
set -euo pipefail

DEST="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
FRAMEWORK_NAME="Chromium Framework.framework"
if [[ "$CONFIGURATION" != "Debug" ]]; then
  rm -rf "$DEST/$FRAMEWORK_NAME"
  exit 0
fi

OUT="${AXO_CHROMIUM_OUT:-$SRCROOT/../axo-chromium/chromium/src/out/Axo}"
SOURCE="$OUT/Chromium.app/Contents/Frameworks/$FRAMEWORK_NAME"
if [[ ! -d "$SOURCE" ]]; then
  rm -rf "$DEST/$FRAMEWORK_NAME"
  echo "note: No Chromium engine at $SOURCE; building Axo without it."
  exit 0
fi

# The copy is about 500 MB, so skip it when neither the engine nor the signing identity changed.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
STAMP="$DERIVED_FILE_DIR/chromium-engine.stamp"
BINARY="$SOURCE/Versions/Current/Chromium Framework"
CURRENT="$(stat -f %m "$BINARY") $IDENTITY"
if [[ -d "$DEST/$FRAMEWORK_NAME" && -f "$STAMP" && "$(cat "$STAMP")" == "$CURRENT" ]]; then
  exit 0
fi

mkdir -p "$DEST" "$DERIVED_FILE_DIR"
rsync -a --delete "$SOURCE" "$DEST/"

# Hardened Runtime's library validation only loads code signed by Axo's team, so re-sign the
# framework and everything inside it, innermost first. The helpers keep running without
# Hardened Runtime (they need JIT); shipping builds will sign them with Chrome's helper
# entitlements instead (Phase 3).
FRAMEWORK="$DEST/$FRAMEWORK_NAME/Versions/Current"
sign() { codesign --force --sign "$IDENTITY" --timestamp=none "$@"; }
find "$FRAMEWORK/Libraries" -type f -name '*.dylib' 2>/dev/null | while read -r library; do sign "$library"; done
for helper in "$FRAMEWORK/Helpers"/*; do sign "$helper"; done
sign "$DEST/$FRAMEWORK_NAME"

echo "$CURRENT" > "$STAMP"
echo "note: Embedded the Chromium engine from $SOURCE."
