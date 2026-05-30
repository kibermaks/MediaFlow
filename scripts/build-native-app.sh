#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/MediaFlow.app"
LEGACY_APP="$ROOT/Image Viewer.app"
OLD_APP="$ROOT/Image Viewer Native.app"
APP_NAME="MediaFlow"
PRODUCT="ImageViewerNative"
EXEC="$ROOT/.build/release/$PRODUCT"
APP_ICON="$ROOT/Assets/AppIcon.icns"
MARKETING_VERSION="${MARKETING_VERSION:-0.4}"
BUILD_NUMBER_FILE="${BUILD_NUMBER_FILE:-$ROOT/BUILD_NUMBER}"
PUBLIC_RELEASE="${PUBLIC_RELEASE:-false}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

BUILD_HOME="$ROOT/.build/home"
SWIFTPM_CACHE="$ROOT/.build/swiftpm-cache"
SWIFTPM_CONFIG="$ROOT/.build/swiftpm-config"
CLANG_CACHE="$ROOT/.build/clang-module-cache"

cd "$ROOT"
mkdir -p "$BUILD_HOME" "$SWIFTPM_CACHE" "$SWIFTPM_CONFIG" "$CLANG_CACHE"

case "$PUBLIC_RELEASE" in
  1|true|TRUE|yes|YES) PUBLIC_RELEASE="true" ;;
  *) PUBLIC_RELEASE="false" ;;
esac

if [[ -n "${BUILD_NUMBER:-}" ]]; then
  RESOLVED_BUILD_NUMBER="$BUILD_NUMBER"
else
  CURRENT_BUILD_NUMBER="1"
  if [[ -f "$BUILD_NUMBER_FILE" ]]; then
    CURRENT_BUILD_NUMBER="$(tr -d '[:space:]' < "$BUILD_NUMBER_FILE")"
  fi
  if [[ ! "$CURRENT_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    CURRENT_BUILD_NUMBER="1"
  fi
  RESOLVED_BUILD_NUMBER=$((CURRENT_BUILD_NUMBER + 1))
  printf "%s\n" "$RESOLVED_BUILD_NUMBER" > "$BUILD_NUMBER_FILE"
fi
BUILD_NUMBER="$RESOLVED_BUILD_NUMBER"

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf "%s" "$value"
}

detect_worktree_name() {
  local git_dir common_dir top_level
  git_dir="$(git rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
  common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  top_level="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$git_dir" && -n "$common_dir" && "$git_dir" != "$common_dir" && -n "$top_level" ]]; then
    basename "$top_level"
  fi
}

WORKTREE_NAME="${WORKTREE_NAME:-$(detect_worktree_name)}"
ESCAPED_MARKETING_VERSION="$(xml_escape "$MARKETING_VERSION")"
ESCAPED_BUILD_NUMBER="$(xml_escape "$BUILD_NUMBER")"
ESCAPED_WORKTREE_NAME="$(xml_escape "$WORKTREE_NAME")"

echo "Building $APP_NAME $MARKETING_VERSION ($BUILD_NUMBER)"
if [[ -n "$WORKTREE_NAME" ]]; then
  echo "Worktree: $WORKTREE_NAME"
fi
if [[ "$PUBLIC_RELEASE" == "true" ]]; then
  echo "Public release metadata: build/worktree hidden in app UI"
fi

HOME="$BUILD_HOME" \
CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" \
swift build \
  --disable-sandbox \
  --cache-path "$SWIFTPM_CACHE" \
  --config-path "$SWIFTPM_CONFIG" \
  -c release \
  -Xswiftc -whole-module-optimization

rm -rf "$APP" "$LEGACY_APP" "$OLD_APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
install -m 755 "$EXEC" "$APP/Contents/MacOS/$APP_NAME"
if [[ -f "$APP_ICON" ]]; then
  cp "$APP_ICON" "$APP/Contents/Resources/AppIcon.icns"
fi
if [[ -f "$ROOT/CHANGELOG.md" ]]; then
  cp "$ROOT/CHANGELOG.md" "$APP/Contents/Resources/CHANGELOG.md"
fi
if [[ -f "$ROOT/LICENSE" ]]; then
  cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>MediaFlow</string>
  <key>CFBundleIdentifier</key>
  <string>com.kibermaks.mediaflow</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Images</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.image</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Movies</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.movie</string>
        <string>public.video</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key>
      <string>MediaFlow Playback</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSHandlerRank</key>
      <string>Owner</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.kibermaks.mediaflow.playback</string>
      </array>
    </dict>
  </array>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>MediaFlow</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$ESCAPED_MARKETING_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$ESCAPED_BUILD_NUMBER</string>
  <key>MediaFlowPublicRelease</key>
  <$PUBLIC_RELEASE/>
  <key>MediaFlowWorktreeName</key>
  <string>$ESCAPED_WORKTREE_NAME</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>MediaFlow imports selected photos and videos into local playback walls.</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key>
      <string>com.kibermaks.mediaflow.playback</string>
      <key>UTTypeDescription</key>
      <string>MediaFlow Playback</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.data</string>
      </array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array>
          <string>ivplayback</string>
        </array>
        <key>public.mime-type</key>
        <string>application/x-mediaflow-playback</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null
/usr/bin/strip -x "$APP/Contents/MacOS/$APP_NAME"

sign_args=(--force --deep --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  sign_args+=(--options runtime --timestamp)
fi
/usr/bin/codesign "${sign_args[@]}" "$APP" >/dev/null
/usr/bin/codesign --verify --deep --strict "$APP"

echo "Built $APP_NAME $MARKETING_VERSION ($BUILD_NUMBER): $APP"
