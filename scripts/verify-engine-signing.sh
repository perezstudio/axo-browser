#!/bin/bash
# Checks that a built Axo.app carries the Chromium engine signed as Chrome signs it (#61): every
# helper has Hardened Runtime, the renderer and GPU helpers have Chrome's JIT entitlement and no
# library validation, the other helpers have library validation, everything is signed by the
# app's team, and the whole bundle verifies strictly. scripts/package-release.sh runs it on the
# exported app; run it by hand on any build signed with a team identity:
#   scripts/verify-engine-signing.sh path/to/Axo.app [--release]
# With --release it also requires a Developer ID signature and secure timestamps, which
# notarization needs.
set -euo pipefail

APP="${1:?usage: verify-engine-signing.sh path/to/Axo.app [--release]}"
RELEASE=0
[[ "${2:-}" == "--release" ]] && RELEASE=1
FRAMEWORK="$APP/Contents/Frameworks/Chromium Framework.framework"
FAILURES=0
fail() { echo "error: $*"; FAILURES=$((FAILURES + 1)); }

[[ -d "$FRAMEWORK" ]] || { echo "error: $APP has no Chromium engine."; exit 1; }

# codesign -d prints its details on stderr.
details() { codesign -d --verbose=4 "$1" 2>&1; }
team_of() { details "$1" | sed -n 's/^TeamIdentifier=//p'; }
entitlements_of() { codesign -d --entitlements - --xml "$1" 2>/dev/null || true; }

TEAM="$(team_of "$APP")"
[[ -n "$TEAM" && "$TEAM" != "not set" ]] || fail "$APP isn't signed with a team identity."

if ! codesign --verify --deep --strict "$APP" 2>"${TMPDIR:-/tmp}/axo-verify.$$"; then
  fail "the bundle doesn't verify: $(cat "${TMPDIR:-/tmp}/axo-verify.$$")"
fi
rm -f "${TMPDIR:-/tmp}/axo-verify.$$"

# Checks an item's team and timestamp, and leaves its CodeDirectory flags in FLAGS.
check() {
  local item="$1" info
  info="$(details "$item")"
  FLAGS="$(sed -n 's/^CodeDirectory .*flags=\(0x[0-9a-f]*\)(\([^)]*\)).*/\2/p' <<<"$info")"
  [[ "$(sed -n 's/^TeamIdentifier=//p' <<<"$info")" == "$TEAM" ]] || fail "$(basename "$item") isn't signed by team $TEAM."
  if [[ "$RELEASE" == 1 ]]; then
    grep -q '^Timestamp=' <<<"$info" || fail "$(basename "$item") has no secure timestamp."
  fi
}

HELPERS=0
for helper in "$FRAMEWORK/Versions/Current/Helpers"/*; do
  HELPERS=$((HELPERS + 1))
  name="$(basename "$helper")"
  check "$helper"
  flags="$FLAGS"
  [[ ",$flags," == *",runtime,"* ]] || fail "$name has no Hardened Runtime (flags: $flags)."
  case "$name" in
    *Renderer\).app|*GPU\).app)
      [[ ",$flags," != *",library-validation,"* ]] || fail "$name has library validation, which rules out JIT."
      entitlements_of "$helper" | grep -q "com.apple.security.cs.allow-jit" || fail "$name lacks Chrome's JIT entitlement."
      ;;
    *)
      [[ ",$flags," == *",library-validation,"* ]] || fail "$name has no library validation (flags: $flags)."
      ;;
  esac
done
[[ "$HELPERS" -gt 0 ]] || fail "the engine has no helpers."

while read -r library; do
  check "$library"
done < <(find "$FRAMEWORK/Versions/Current/Libraries" -type f -name '*.dylib')
check "$FRAMEWORK"

if [[ "$RELEASE" == 1 ]]; then
  details "$APP" | grep -q '^Authority=Developer ID Application' || fail "Axo isn't signed with a Developer ID."
  check "$APP"
  [[ ",$FLAGS," == *",runtime,"* ]] || fail "Axo has no Hardened Runtime."
  entitlements_of "$APP" | grep -q "com.apple.security.get-task-allow" && fail "Axo allows debugging (get-task-allow), which notarization refuses."
fi

if [[ "$FAILURES" -gt 0 ]]; then
  echo "$FAILURES signing problem(s) in $APP."
  exit 1
fi
echo "The engine in $APP is signed as Chrome signs it."
