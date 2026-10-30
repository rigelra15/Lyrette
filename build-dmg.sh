#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAVED_DIR="$(pwd)"
cd "$SCRIPT_DIR"

# Build .app first if not provided
APP_PATH="${1:-LyricBar.xcarchive/Products/Applications/LyricBar.app}"
if [ ! -d "$APP_PATH" ]; then
    echo "==> Building .app..."
    xcodebuild archive \
        -project LyricBar.xcodeproj \
        -scheme LyricBar \
        -configuration Release \
        -archivePath LyricBar.xcarchive \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO
fi

SPEC="${SCRIPT_DIR}/dmg-spec.json"
RW_DMG="${SCRIPT_DIR}/LyricBar_rw.dmg"
VERSION=$(grep -m1 MARKETING_VERSION "${SCRIPT_DIR}/LyricBar.xcodeproj/project.pbxproj" | sed -E 's/.*= ([^;]+);.*/\1/')
FINAL_DMG="${SCRIPT_DIR}/LyricBar ${VERSION}.dmg"
APPDMG="${HOME}/.nvm/versions/node/v22.22.2/lib/node_modules/create-dmg/node_modules/.bin/appdmg"

echo "==> Building DMG with appdmg..."
"$APPDMG" "$SPEC" "$FINAL_DMG"

echo "==> Converting to read-write..."
hdiutil convert "$FINAL_DMG" -format UDRW -o "$RW_DMG"

echo "==> Mounting read-write..."
DEV=$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen | egrep '^/dev/' | sed 1q | awk '{print $1}')
MOUNT="/Volumes/LyricBar"

echo "==> Applying custom layout..."
osascript <<'APPLESCRIPT'
tell application "Finder"
    tell disk "LyricBar"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 200, 1060, 600}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 160
        set background picture of viewOptions to file ".background:dmg-background.png"
        set position of item "LyricBar.app" of container window to {180, 170}
        set position of item "Applications" of container window to {480, 170}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

echo "==> Setting volume icon..."
ICON_SRC="${APP_PATH}/Contents/Resources/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "${MOUNT}/.VolumeIcon.icns"
    SetFile -a C "${MOUNT}"
fi

echo "==> Finalizing..."
sync
hdiutil detach "$DEV" -force
for try in 1 2 3 4 5; do
    if hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL_DMG" 2>/dev/null; then
        break
    fi
    sleep 2
done
rm -f "$RW_DMG"

cd "$SAVED_DIR"
echo "==> Done: $FINAL_DMG"
