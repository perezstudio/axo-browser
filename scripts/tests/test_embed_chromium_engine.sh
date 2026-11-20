#!/bin/bash
# Checks how scripts/embed-chromium-engine.sh signs the engine (#61), against a stand-in engine
# and a stand-in `codesign` that records its arguments, so it needs no engine, identity, or
# network. Run it from anywhere: scripts/tests/test_embed_chromium_engine.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

fail() { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }

# A copy of Axo's side (the script, the entitlements, the API header), so the test can change it.
SRC="$WORK/src"
HEADER="Packages/AxoChromium/Sources/AxoEngineAPI/include/AxoEngineProtocols.h"
mkdir -p "$SRC/scripts" "$(dirname "$SRC/$HEADER")"
cp "$ROOT/scripts/embed-chromium-engine.sh" "$SRC/scripts/"
cp -R "$ROOT/scripts/engine-entitlements" "$SRC/scripts/"
cp "$ROOT/$HEADER" "$SRC/$HEADER"

# Chrome's helper entitlements, unchanged: only the JIT entitlement.
for plist in "$ROOT/scripts/engine-entitlements"/*.plist; do
  keys="$(plutil -convert json -o - "$plist")"
  [[ "$keys" == '{"com.apple.security.cs.allow-jit":true}' ]] || fail "$(basename "$plist") isn't Chrome's: $keys"
done

# A stand-in engine with Chrome's helpers and libraries, in a stand-in fork with its API header.
FORK="$WORK/fork"
OUT="$FORK/chromium/src/out/Axo"
mkdir -p "$FORK/axo/public"
cp "$ROOT/$HEADER" "$FORK/axo/public/"
FRAMEWORK="$OUT/Chromium.app/Contents/Frameworks/Chromium Framework.framework"
VERSION="$FRAMEWORK/Versions/A"
mkdir -p "$VERSION/Helpers" "$VERSION/Libraries" "$VERSION/Resources"
ln -s A "$FRAMEWORK/Versions/Current"
echo binary > "$VERSION/Chromium Framework"
for app in "Chromium Helper" "Chromium Helper (Renderer)" "Chromium Helper (GPU)" \
  "Chromium Helper (Alerts)" "Chromium Helper (Aperitif)" "Chromium Helper (Aperitif Renderer)" \
  "Chromium Helper (Aperitif GPU)" "Chromium Helper (Aperitif Alerts)"; do
  mkdir -p "$VERSION/Helpers/$app.app/Contents/MacOS"
done
for tool in app_mode_loader chrome_crashpad_handler web_app_shortcut_copier; do
  echo tool > "$VERSION/Helpers/$tool"
done
for library in libaperitif.dylib libvk_swiftshader.dylib libvulkan.dylib; do
  echo library > "$VERSION/Libraries/$library"
done
echo '{}' > "$VERSION/Libraries/vk_swiftshader_icd.json"

# A stand-in codesign: one line per call, its arguments joined by "|".
mkdir -p "$WORK/bin"
cat > "$WORK/bin/codesign" <<'EOF'
#!/bin/bash
(IFS='|'; echo "$*") >> "$CODESIGN_LOG"
EOF
chmod +x "$WORK/bin/codesign"

# Runs the embed phase as Xcode would, with the given configuration and identity.
embed() {
  local configuration="$1" identity="$2" out="${3:-$OUT}"
  : > "$WORK/codesign.log"
  PATH="$WORK/bin:$PATH" CODESIGN_LOG="$WORK/codesign.log" \
    SRCROOT="$SRC" TARGET_BUILD_DIR="$WORK/build" FRAMEWORKS_FOLDER_PATH="Axo.app/Contents/Frameworks" \
    DERIVED_FILE_DIR="$WORK/derived" AXO_CHROMIUM_OUT="$out" CONFIGURATION="$configuration" \
    EXPANDED_CODE_SIGN_IDENTITY="$identity" \
    "$SRC/scripts/embed-chromium-engine.sh" > "$WORK/embed.log" 2>&1
}

# The recorded call that signed the item whose path ends with `$1`.
call_for() { grep -E "/$(printf '%s' "$1" | sed 's/[][().]/\\&/g')$" "$WORK/codesign.log" || true; }

expect_call() {
  local item="$1" expected="$2" call
  call="$(call_for "$item")"
  [[ -n "$call" ]] || { fail "$item wasn't signed"; return; }
  [[ "$call" == *"$expected"* ]] || fail "$item was signed with '$call', expected '$expected'"
}

refuse_call() {
  local item="$1" unexpected="$2" call
  call="$(call_for "$item")"
  [[ "$call" != *"$unexpected"* ]] || fail "$item was signed with '$call', which shouldn't have '$unexpected'"
}

# A team identity, Debug: Chrome's options, no timestamp.
embed Debug "ABCDEF1234567890"
RUNTIME_JIT="--options|restrict,kill,runtime|--entitlements|$SRC/scripts/engine-entitlements"
for helper in "Chromium Helper (Renderer).app" "Chromium Helper (Aperitif Renderer).app"; do
  expect_call "$helper" "$RUNTIME_JIT/helper-renderer.plist"
done
for helper in "Chromium Helper (GPU).app" "Chromium Helper (Aperitif GPU).app"; do
  expect_call "$helper" "$RUNTIME_JIT/helper-gpu.plist"
done
for helper in "Chromium Helper.app" "Chromium Helper (Alerts).app" "Chromium Helper (Aperitif).app" \
  "Chromium Helper (Aperitif Alerts).app" app_mode_loader chrome_crashpad_handler web_app_shortcut_copier; do
  expect_call "$helper" "--options|restrict,library,kill,runtime"
  refuse_call "$helper" "--entitlements"
done
for library in libaperitif.dylib libvk_swiftshader.dylib libvulkan.dylib; do
  expect_call "$library" "--sign|ABCDEF1234567890|--timestamp=none"
  refuse_call "$library" "--options"
done
grep -q "vk_swiftshader_icd.json" "$WORK/codesign.log" && fail "a non-library file in Libraries was signed"
[[ "$(tail -1 "$WORK/codesign.log")" == *"/Chromium Framework.framework" ]] || fail "the framework wasn't signed last"
[[ "$(grep -c . "$WORK/codesign.log")" == 15 ]] || fail "expected 15 signatures, got $(grep -c . "$WORK/codesign.log")"
[[ -f "$WORK/build/Axo.app/Contents/Frameworks/Chromium Framework.framework/Versions/A/Chromium Framework" ]] \
  || fail "the framework wasn't copied into the app"

# Unchanged: nothing is copied or signed again.
embed Debug "ABCDEF1234567890"
[[ ! -s "$WORK/codesign.log" ]] || fail "an unchanged engine was signed again"

# Changed entitlements: signed again.
echo "<!-- changed -->" >> "$SRC/scripts/engine-entitlements/helper-gpu.plist"
embed Debug "ABCDEF1234567890"
[[ -s "$WORK/codesign.log" ]] || fail "changed entitlements didn't sign the engine again"

# Release: the same options with a secure timestamp, which notarization needs.
embed Release "ABCDEF1234567890"
expect_call "Chromium Helper (Renderer).app" "--sign|ABCDEF1234567890|--timestamp|$RUNTIME_JIT/helper-renderer.plist"
expect_call "Chromium Helper.app" "--timestamp|--options|restrict,library,kill,runtime"
expect_call "libvulkan.dylib" "--timestamp|"
grep -q -- "--timestamp=none" "$WORK/codesign.log" && fail "a Release build signed something without a timestamp"

# Ad hoc (CI): no team for library validation, so no Hardened Runtime on the helpers.
embed Debug "-"
for helper in "Chromium Helper.app" "Chromium Helper (Renderer).app" chrome_crashpad_handler; do
  expect_call "$helper" "--sign|-|--timestamp=none"
  refuse_call "$helper" "--options"
done

# No engine: Debug warns and builds; Release fails.
if embed Debug "-" "$WORK/missing"; then
  grep -q "warning: No Chromium engine" "$WORK/embed.log" || fail "a Debug build without an engine didn't warn"
  [[ ! -e "$WORK/build/Axo.app/Contents/Frameworks/Chromium Framework.framework" ]] \
    || fail "a Debug build without an engine kept the old copy"
else
  fail "a Debug build without an engine failed"
fi
if embed Release "-" "$WORK/missing"; then
  fail "a Release build without an engine succeeded"
else
  grep -q "error: No Chromium engine" "$WORK/embed.log" || fail "a Release build without an engine didn't say why"
fi

# An API header that differs from the fork's fails the build.
echo "// changed" >> "$SRC/$HEADER"
if embed Debug "-"; then
  fail "a header that differs from the fork's built"
else
  grep -q "differs from the fork's" "$WORK/embed.log" || fail "a differing header didn't say why"
fi

if [[ "$FAILURES" -gt 0 ]]; then
  echo "$FAILURES check(s) failed."
  exit 1
fi
echo "The embed phase signs the engine as Chrome does."
