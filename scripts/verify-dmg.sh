#!/bin/zsh
set -uo pipefail

APP_NAME="${APP_NAME:-MediaFlow}"
DMG_PATH="${1:-}"

if [[ -z "$DMG_PATH" ]]; then
  dmg_candidates=(dmg_output/*.dmg(N))
  if (( ${#dmg_candidates[@]} > 0 )); then
    DMG_PATH="$(ls -t "${dmg_candidates[@]}" | head -1)"
  fi
fi

if [[ -z "$DMG_PATH" || ! -f "$DMG_PATH" ]]; then
  echo "Usage: ./scripts/verify-dmg.sh <path-to-dmg>" >&2
  exit 1
fi

pass=0
fail=0
warn=0
volume=""

check() {
  local label="$1"
  shift
  if "$@"; then
    printf "PASS  %s\n" "$label"
    pass=$((pass + 1))
  else
    printf "FAIL  %s\n" "$label"
    fail=$((fail + 1))
  fi
}

warning() {
  local label="$1"
  shift
  if "$@"; then
    printf "PASS  %s\n" "$label"
    pass=$((pass + 1))
  else
    printf "WARN  %s\n" "$label"
    warn=$((warn + 1))
  fi
}

cleanup() {
  if [[ -n "$volume" ]]; then
    /usr/bin/hdiutil detach "$volume" -force >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "Verifying $DMG_PATH"
warning "DMG signature verifies" /usr/bin/codesign --verify --verbose=4 "$DMG_PATH"
warning "DMG notarization stapled" /usr/bin/xcrun stapler validate "$DMG_PATH"

volume="$(/usr/bin/hdiutil attach "$DMG_PATH" -nobrowse 2>/dev/null | awk '/\/Volumes\// {print substr($0, index($0, "/Volumes/")); exit}')"
if [[ -z "$volume" ]]; then
  echo "Could not mount DMG" >&2
  exit 1
fi

app_path="$volume/$APP_NAME.app"

check "App bundle exists" test -d "$app_path"
check "Applications symlink exists" test -L "$volume/Applications"
check "Info.plist is valid" /usr/bin/plutil -lint "$app_path/Contents/Info.plist"
check "Code signature verifies" /usr/bin/codesign --verify --deep --strict "$app_path"
warning "Gatekeeper accepts app" /usr/sbin/spctl --assess --type execute "$app_path"

echo "Results: $pass passed, $fail failed, $warn warnings"
exit "$fail"
