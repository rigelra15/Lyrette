#!/bin/bash
# LyricBar uninstaller.
#   curl -fsSL https://raw.githubusercontent.com/rigelra15/LyricBar/main/uninstall.sh | bash
# Keep your cached lyrics and settings:  ... | KEEP_DATA=1 bash
set -euo pipefail

BUNDLE_ID="com.rigelra.LyricBar"
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

if pgrep -x LyricBar >/dev/null 2>&1; then
    say "Quitting LyricBar..."
    osascript -e 'tell application "LyricBar" to quit' >/dev/null 2>&1 || pkill -x LyricBar || true
    sleep 1
fi

for dir in /Applications "$HOME/Applications"; do
    if [ -d "$dir/LyricBar.app" ]; then
        say "Removing $dir/LyricBar.app"
        if [ -w "$dir" ]; then rm -rf "$dir/LyricBar.app"; else sudo rm -rf "$dir/LyricBar.app"; fi
    fi
done

if [ -z "${KEEP_DATA:-}" ]; then
    say "Removing cached lyrics, artwork and settings..."
    rm -rf "$HOME/Library/Application Support/LyricBarCache"
    rm -rf "$HOME/Library/Caches/$BUNDLE_ID"
    rm -f  "$HOME/Library/Preferences/$BUNDLE_ID.plist"
    rm -rf "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    killall cfprefsd >/dev/null 2>&1 || true
fi

# Drop the Automation (Music/Spotify) permission entries so a reinstall asks again.
tccutil reset AppleEvents "$BUNDLE_ID" >/dev/null 2>&1 || true

printf '\n\033[1;32m✓ LyricBar removed.\033[0m\n'
printf '  If it still shows under System Settings → General → Login Items, remove it there.\n'
