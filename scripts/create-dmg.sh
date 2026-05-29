#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-MediaFlow}"
APP_FILE="${APP_FILE:-$APP_NAME.app}"
SOURCE_APP="${APP_SOURCE:-$ROOT/$APP_FILE}"
DMG_DIR="${DMG_DIR:-$ROOT/dmg_output}"
VOLUME_NAME="${DMG_VOLUME_NAME:-$APP_NAME Installer}"
WINDOW_LEFT="${DMG_WINDOW_LEFT:-240}"
WINDOW_TOP="${DMG_WINDOW_TOP:-100}"
WINDOW_WIDTH="${DMG_WINDOW_WIDTH:-760}"
WINDOW_HEIGHT="${DMG_WINDOW_HEIGHT:-440}"
ICON_SIZE="${DMG_ICON_SIZE:-104}"
APP_POS_X="${DMG_APP_POS_X:-220}"
APP_POS_Y="${DMG_APP_POS_Y:-245}"
APPLICATIONS_POS_X="${DMG_APPLICATIONS_POS_X:-560}"
APPLICATIONS_POS_Y="${DMG_APPLICATIONS_POS_Y:-245}"
SKIP_FINDER_LAYOUT="${SKIP_FINDER_LAYOUT:-false}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Missing app bundle: $SOURCE_APP" >&2
  echo "Run ./scripts/build-native-app.sh first." >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_APP/Contents/Info.plist")"
DMG_FILENAME="${DMG_FILENAME:-$APP_NAME-$VERSION.dmg}"
DMG_PATH="$DMG_DIR/$DMG_FILENAME"
TEMP_DIR="$DMG_DIR/temp_dmg"
TEMP_DMG="$DMG_DIR/temp.dmg"
BACKGROUND_DIR="$TEMP_DIR/.background"
BACKGROUND_IMAGE="$BACKGROUND_DIR/dmg-background.png"
MOUNT_DIR="/Volumes/$VOLUME_NAME"

cleanup() {
  /usr/bin/hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
  if [[ -f "$TEMP_DMG" ]]; then
    /usr/bin/hdiutil detach "$TEMP_DMG" -force >/dev/null 2>&1 || true
  fi
  /bin/rm -rf "$TEMP_DIR" "$TEMP_DMG"
}
trap cleanup EXIT

remove_packaging_metadata() {
  local target_path="$1"
  /usr/bin/find "$target_path" \( -name '._*' -o -name '.DS_Store' \) -exec /bin/rm -f {} +
}

remove_dmg_volume_metadata() {
  local target_path="$1"
  /bin/rm -rf \
    "$target_path/.fseventsd" \
    "$target_path/.Spotlight-V100" \
    "$target_path/.TemporaryItems" \
    "$target_path/.Trashes"
}

create_dmg_background() {
  local output="$1"
  /bin/mkdir -p "$(/usr/bin/dirname "$output")"
  /usr/bin/swift - "$output" "$WINDOW_WIDTH" "$WINDOW_HEIGHT" "$APP_POS_X" "$APP_POS_Y" "$APPLICATIONS_POS_X" "$APPLICATIONS_POS_Y" <<'SWIFT'
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let width = CGFloat(Double(CommandLine.arguments[2]) ?? 760)
let height = CGFloat(Double(CommandLine.arguments[3]) ?? 440)
let appX = CGFloat(Double(CommandLine.arguments[4]) ?? 220)
let appY = CGFloat(Double(CommandLine.arguments[5]) ?? 245)
let applicationsX = CGFloat(Double(CommandLine.arguments[6]) ?? 560)
let applicationsY = CGFloat(Double(CommandLine.arguments[7]) ?? 245)

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()

let bounds = NSRect(x: 0, y: 0, width: width, height: height)
NSGradient(colors: [
    NSColor(calibratedRed: 0.055, green: 0.061, blue: 0.070, alpha: 1.0),
    NSColor(calibratedRed: 0.115, green: 0.125, blue: 0.145, alpha: 1.0)
])?.draw(in: bounds, angle: -90)

func drawGlow(center: NSPoint, radius: CGFloat, color: NSColor) {
    let rect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    NSGradient(colors: [
        color.withAlphaComponent(0.28),
        color.withAlphaComponent(0.0)
    ])?.draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: .zero)
}

drawGlow(center: NSPoint(x: width * 0.24, y: height * 0.72), radius: 210, color: NSColor(calibratedRed: 0.04, green: 0.78, blue: 0.88, alpha: 1))
drawGlow(center: NSPoint(x: width * 0.82, y: height * 0.25), radius: 230, color: NSColor(calibratedRed: 0.55, green: 0.23, blue: 0.95, alpha: 1))

let arrowY = min(appY, applicationsY) - 26
let arrowStart = NSPoint(x: appX + 92, y: arrowY)
let arrowEnd = NSPoint(x: applicationsX - 92, y: arrowY)

let shadow = NSBezierPath()
shadow.move(to: NSPoint(x: arrowStart.x + 0, y: arrowStart.y - 2))
shadow.line(to: NSPoint(x: arrowEnd.x + 0, y: arrowEnd.y - 2))
shadow.lineWidth = 7
shadow.lineCapStyle = .round
NSColor.black.withAlphaComponent(0.30).setStroke()
shadow.stroke()

let arrow = NSBezierPath()
arrow.move(to: arrowStart)
arrow.line(to: arrowEnd)
arrow.lineWidth = 6
arrow.lineCapStyle = .round
NSColor(calibratedRed: 0.10, green: 0.86, blue: 0.92, alpha: 0.92).setStroke()
arrow.stroke()

let highlight = NSBezierPath()
highlight.move(to: NSPoint(x: arrowStart.x + 10, y: arrowStart.y + 2))
highlight.line(to: NSPoint(x: arrowEnd.x - 18, y: arrowEnd.y + 2))
highlight.lineWidth = 2
highlight.lineCapStyle = .round
NSColor(calibratedRed: 0.72, green: 0.93, blue: 1.00, alpha: 0.64).setStroke()
highlight.stroke()

let headSize: CGFloat = 24
let arrowHead = NSBezierPath()
arrowHead.move(to: arrowEnd)
arrowHead.line(to: NSPoint(x: arrowEnd.x - headSize, y: arrowEnd.y + 17))
arrowHead.move(to: arrowEnd)
arrowHead.line(to: NSPoint(x: arrowEnd.x - headSize, y: arrowEnd.y - 17))
arrowHead.lineWidth = 6
arrowHead.lineCapStyle = .round
NSColor(calibratedRed: 0.68, green: 0.35, blue: 1.00, alpha: 0.95).setStroke()
arrowHead.stroke()

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("Could not render DMG background\n", stderr)
    exit(1)
}

try png.write(to: output)
SWIFT
}

cleanup
rm -rf "$DMG_DIR"
mkdir -p "$TEMP_DIR" "$BACKGROUND_DIR"

COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$SOURCE_APP" "$TEMP_DIR/$APP_FILE"
/bin/ln -s /Applications "$TEMP_DIR/Applications"
create_dmg_background "$BACKGROUND_IMAGE"
remove_packaging_metadata "$TEMP_DIR"

/usr/bin/hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$TEMP_DIR" \
  -ov \
  -fs HFS+ \
  -format UDRW \
  "$TEMP_DMG" \
  >/dev/null

if [[ "$SKIP_FINDER_LAYOUT" != "true" ]]; then
  ATTACH_OUTPUT="$(/usr/bin/hdiutil attach "$TEMP_DMG" -readwrite -noverify -noautoopen -nobrowse)"
  MOUNT_DIR="$(printf '%s\n' "$ATTACH_OUTPUT" | /usr/bin/awk -F '\t' '/^\/dev\// { mount=$NF } END { print mount }')"
  if [[ -z "$MOUNT_DIR" ]]; then
    echo "Could not determine DMG mount path." >&2
    printf '%s\n' "$ATTACH_OUTPUT" >&2
    exit 1
  fi
  /usr/bin/chflags hidden "$MOUNT_DIR/.background" 2>/dev/null || true
  /bin/sleep 2
  WINDOW_RIGHT=$((WINDOW_LEFT + WINDOW_WIDTH))
  WINDOW_BOTTOM=$((WINDOW_TOP + WINDOW_HEIGHT))

  /usr/bin/osascript - "$(basename "$MOUNT_DIR")" "$APP_FILE" "$WINDOW_LEFT" "$WINDOW_TOP" "$WINDOW_RIGHT" "$WINDOW_BOTTOM" "$ICON_SIZE" "$APP_POS_X" "$APP_POS_Y" "$APPLICATIONS_POS_X" "$APPLICATIONS_POS_Y" <<'APPLESCRIPT'
on run argv
set volumeName to item 1 of argv
set appFile to item 2 of argv
set windowLeft to item 3 of argv as integer
set windowTop to item 4 of argv as integer
set windowRight to item 5 of argv as integer
set windowBottom to item 6 of argv as integer
set dmgIconSize to item 7 of argv as integer
set appPosX to item 8 of argv as integer
set appPosY to item 9 of argv as integer
set applicationsPosX to item 10 of argv as integer
set applicationsPosY to item 11 of argv as integer

with timeout of 30 seconds
tell application "Finder"
  tell disk (volumeName as string)
    open
    delay 1

    tell container window
      set current view to icon view
      set toolbar visible to false
      set statusbar visible to false
      try
        set pathbar visible to false
      end try
      set the bounds to {windowLeft, windowTop, windowRight, windowBottom}
    end tell

    set theViewOptions to the icon view options of container window
    tell theViewOptions
      set arrangement to not arranged
      set icon size to dmgIconSize
    end tell
    set background picture of theViewOptions to file ".background:dmg-background.png"
    set position of item appFile of container window to {appPosX, appPosY}
    set position of item "Applications" of container window to {applicationsPosX, applicationsPosY}

    update without registering applications
    delay 1
    close
  end tell
end tell
end timeout
end run
APPLESCRIPT

  /bin/sync
  remove_dmg_volume_metadata "$MOUNT_DIR"
  /bin/sleep 1
  /usr/bin/hdiutil detach "$MOUNT_DIR" -force >/dev/null
fi

/usr/bin/hdiutil convert "$TEMP_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH" \
  >/dev/null

if [[ -n "$SIGN_IDENTITY" && "$SIGN_IDENTITY" != "-" ]]; then
  /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH" >/dev/null
fi

echo "Created $APP_NAME $VERSION ($BUILD) DMG: $DMG_PATH"
