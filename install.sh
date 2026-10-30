#!/bin/bash
# LyricBar installer.
#   curl -fsSL https://raw.githubusercontent.com/rigelra15/LyricBar/main/install.sh | bash
# Install a specific version:  ... | VERSION=1.0.23 bash
set -euo pipefail

REPO="rigelra15/LyricBar"
APP_NAME="LyricBar.app"
DEST="${INSTALL_DIR:-/Applications}"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "LyricBar only runs on macOS."

if [ -n "${VERSION:-}" ]; then
    API="https://api.github.com/repos/${REPO}/releases/tags/v${VERSION#v}"
else
    API="https://api.github.com/repos/${REPO}/releases/latest"
fi

say "Looking up the release..."
JSON=$(curl -fsSL -H "Accept: application/vnd.github+json" "$API") || die "Couldn't reach GitHub (or that version doesn't exist)."
DMG_URL=$(printf '%s' "$JSON" | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/')
TAG=$(printf '%s' "$JSON" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
[ -n "$DMG_URL" ] || die "No .dmg found in that release."

WORK=$(mktemp -d)
MOUNT="$WORK/mount"
cleanup() {
    hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

say "Downloading LyricBar ${TAG}..."
curl -fL --progress-bar "$DMG_URL" -o "$WORK/LyricBar.dmg"

say "Mounting disk image..."
mkdir -p "$MOUNT"
hdiutil attach "$WORK/LyricBar.dmg" -nobrowse -readonly -noautoopen -quiet -mountpoint "$MOUNT"
[ -d "$MOUNT/$APP_NAME" ] || die "$APP_NAME not found in the disk image."

if pgrep -x LyricBar >/dev/null 2>&1; then
    say "Quitting running LyricBar..."
    osascript -e 'tell application "LyricBar" to quit' >/dev/null 2>&1 || pkill -x LyricBar || true
    sleep 1
fi

SUDO=""
if [ ! -w "$DEST" ]; then
    say "Need administrator rights to write to $DEST"
    SUDO="sudo"
fi

say "Installing to $DEST..."
$SUDO rm -rf "$DEST/$APP_NAME"
$SUDO ditto "$MOUNT/$APP_NAME" "$DEST/$APP_NAME"
# The app isn't notarized; clear the quarantine flag so Gatekeeper doesn't block it.
$SUDO xattr -dr com.apple.quarantine "$DEST/$APP_NAME" 2>/dev/null || true

say "Launching LyricBar..."
open "$DEST/$APP_NAME"

printf '\n\033[1;32m✓ LyricBar %s installed.\033[0m Play a song in Apple Music or Spotify.\n' "$TAG"
printf '  Uninstall any time:  curl -fsSL https://raw.githubusercontent.com/%s/main/uninstall.sh | bash\n' "$REPO"
