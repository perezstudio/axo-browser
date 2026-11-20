#!/bin/bash
# Run by the Axo target's "Embed Chromium Engine" build phase. Copies the Chromium engine
# framework built by the axo-chromium fork into Axo.app/Contents/Frameworks and signs it with
# Axo's identity. The Mac runs every tab on it, with no WebKit fallback (see
# docs/chromium-engine.md), so a Debug build without an engine warns: it builds, but the app says
# the engine is missing and quits (test runs still use WebKit). A Release build without one fails,
# since it could never open (scripts/package-release.sh makes the DMG from Release).
#
# The engine comes from $AXO_CHROMIUM_OUT, or from a sibling checkout of axo-chromium:
#   ../axo-chromium/chromium/src/out/Axo
# (next to the main checkout when building from a git worktree).
set -euo pipefail

DEST="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
FRAMEWORK_NAME="Chromium Framework.framework"
OUT="${AXO_CHROMIUM_OUT:-$SRCROOT/../axo-chromium/chromium/src/out/Axo}"
# In a git worktree, the sibling checkout sits next to the main checkout instead.
if [[ -z "${AXO_CHROMIUM_OUT:-}" && ! -d "$OUT" ]]; then
  COMMON="$(git -C "$SRCROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -n "$COMMON" ]]; then
    OUT="$(dirname "$(dirname "$COMMON")")/axo-chromium/chromium/src/out/Axo"
  fi
fi
SOURCE="$OUT/Chromium.app/Contents/Frameworks/$FRAMEWORK_NAME"

# Axo's copy of the engine's API header must match the fork's (CLAUDE.md, "The API header").
FORK_HEADER="$OUT/../../../../axo/public/AxoEngineProtocols.h"
AXO_HEADER="$SRCROOT/Packages/AxoChromium/Sources/AxoEngineAPI/include/AxoEngineProtocols.h"
if [[ -f "$FORK_HEADER" ]] && ! cmp -s "$FORK_HEADER" "$AXO_HEADER"; then
  echo "error: $AXO_HEADER differs from the fork's $FORK_HEADER. Copy the fork's over it."
  exit 1
fi

if [[ ! -d "$SOURCE" ]]; then
  rm -rf "$DEST/$FRAMEWORK_NAME"
  if [[ "${CONFIGURATION:-}" == "Release" ]]; then
    echo "error: No Chromium engine at $SOURCE. Release builds must embed it: build axo-chromium next to Axo (or set AXO_CHROMIUM_OUT)."
    exit 1
  fi
  echo "warning: No Chromium engine at $SOURCE. Build axo-chromium next to Axo (or set AXO_CHROMIUM_OUT); without it Axo can't open."
  exit 0
fi

# The copy is about 500 MB, so skip it when neither the engine, the signing identity, the build
# configuration, nor how this script signs (itself and the helpers' entitlements) changed.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
STAMP="$DERIVED_FILE_DIR/chromium-engine.stamp"
BINARY="$SOURCE/Versions/Current/Chromium Framework"
CURRENT="$(stat -f %m "$BINARY") $IDENTITY ${CONFIGURATION:-} $(cat "$0" "$SRCROOT/scripts/engine-entitlements"/*.plist | shasum | cut -c1-12)"
if [[ -d "$DEST/$FRAMEWORK_NAME" && -f "$STAMP" && "$(cat "$STAMP")" == "$CURRENT" ]]; then
  exit 0
fi

mkdir -p "$DEST" "$DERIVED_FILE_DIR"
rsync -a --delete "$SOURCE" "$DEST/"

# Hardened Runtime's library validation only loads code signed by Axo's team, so re-sign the
# framework and everything inside it, innermost first, as Chrome's own signing does
# (chrome/installer/mac/signing/parts.py): the renderer and GPU helpers get Hardened Runtime with
# Chrome's JIT entitlement and no library validation (V8 needs JIT, which library validation
# rules out), and every other helper Hardened Runtime with library validation. An ad hoc
# signature has no team, so library validation would refuse the framework: ad hoc builds (CI)
# sign the helpers without Hardened Runtime, as before. Release builds add a secure timestamp,
# which notarization needs.
FRAMEWORK="$DEST/$FRAMEWORK_NAME/Versions/Current"
ENTITLEMENTS="$SRCROOT/scripts/engine-entitlements"
TIMESTAMP="--timestamp=none"
[[ "${CONFIGURATION:-}" == "Release" ]] && TIMESTAMP="--timestamp"
sign() { codesign --force --sign "$IDENTITY" "$TIMESTAMP" "$@"; }
sign_helper() {
  local helper="$1"
  if [[ "$IDENTITY" == "-" ]]; then
    sign "$helper"
    return
  fi
  case "$(basename "$helper")" in
    *Renderer\).app) sign --options restrict,kill,runtime --entitlements "$ENTITLEMENTS/helper-renderer.plist" "$helper" ;;
    *GPU\).app) sign --options restrict,kill,runtime --entitlements "$ENTITLEMENTS/helper-gpu.plist" "$helper" ;;
    *) sign --options restrict,library,kill,runtime "$helper" ;;
  esac
}
[[ -d "$FRAMEWORK/Libraries" ]] && find "$FRAMEWORK/Libraries" -type f -name '*.dylib' | sort | while read -r library; do sign "$library"; done
for helper in "$FRAMEWORK/Helpers"/*; do sign_helper "$helper"; done
sign "$DEST/$FRAMEWORK_NAME"

echo "$CURRENT" > "$STAMP"
echo "note: Embedded the Chromium engine from $SOURCE."
