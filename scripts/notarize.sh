#!/bin/zsh
set -euo pipefail

ARTIFACT="${1:-}"
KEYCHAIN_PROFILE="${2:-MediaFlow}"

if [[ -z "$ARTIFACT" ]]; then
  echo "Usage: ./scripts/notarize.sh <path-to-app-or-dmg> [keychain-profile]" >&2
  echo "" >&2
  echo "One-time setup example:" >&2
  echo "  xcrun notarytool store-credentials \"MediaFlow\" \\" >&2
  echo "    --apple-id \"your@email.com\" \\" >&2
  echo "    --team-id \"YOURTEAMID\" \\" >&2
  echo "    --password \"app-specific-password\"" >&2
  exit 1
fi

if [[ ! -e "$ARTIFACT" ]]; then
  echo "Not found: $ARTIFACT" >&2
  exit 1
fi

cleanup_zip=""
if [[ "$ARTIFACT" == *.app ]]; then
  submit_path="$(mktemp /tmp/mediaflow_notarize_XXXXXXXX).zip"
  cleanup_zip="$submit_path"
  /usr/bin/ditto -c -k --keepParent "$ARTIFACT" "$submit_path"
elif [[ "$ARTIFACT" == *.dmg ]]; then
  submit_path="$ARTIFACT"
else
  echo "Unsupported artifact type. Provide a .app or .dmg." >&2
  exit 1
fi

cleanup() {
  if [[ -n "$cleanup_zip" ]]; then
    rm -f "$cleanup_zip"
  fi
}
trap cleanup EXIT

/usr/bin/xcrun notarytool submit "$submit_path" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait

/usr/bin/xcrun stapler staple "$ARTIFACT"
/usr/bin/xcrun stapler validate "$ARTIFACT"

echo "Notarized and stapled: $ARTIFACT"
