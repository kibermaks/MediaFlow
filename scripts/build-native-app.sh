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
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

BUILD_HOME="$ROOT/.build/home"
SWIFTPM_CACHE="$ROOT/.build/swiftpm-cache"
SWIFTPM_CONFIG="$ROOT/.build/swiftpm-config"
CLANG_CACHE="$ROOT/.build/clang-module-cache"

cd "$ROOT"
mkdir -p "$BUILD_HOME" "$SWIFTPM_CACHE" "$SWIFTPM_CONFIG" "$CLANG_CACHE"

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
  </array>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>MediaFlow</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$MARKETING_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>MediaFlow imports selected photos and videos into local playback walls.</string>
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
