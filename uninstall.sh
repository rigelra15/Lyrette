#!/bin/bash
# Lyrette uninstaller (also removes LyricBar, its former name).
#   curl -fsSL https://raw.githubusercontent.com/rigelra15/Lyrette/main/uninstall.sh | bash
# Keep your cached lyrics and settings:  ... | KEEP_DATA=1 bash
set -euo pipefail

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

for name in Lyrette LyricBar; do
    if pgrep -x "$name" >/dev/null 2>&1; then
        say "Quitting $name..."
        osascript -e "tell application \"$name\" to quit" >/dev/null 2>&1 || pkill -x "$name" || true
        sleep 1
    fi

    for dir in /Applications "$HOME/Applications"; do
        if [ -d "$dir/$name.app" ]; then
            say "Removing $dir/$name.app"
            if [ -w "$dir" ]; then rm -rf "$dir/$name.app"; else sudo rm -rf "$dir/$name.app"; fi
        fi
    done

    bundle_id="com.rigelra.$name"
    if [ -z "${KEEP_DATA:-}" ]; then
        rm -rf "$HOME/Library/Application Support/${name}Cache"
        rm -rf "$HOME/Library/Caches/$bundle_id"
        rm -f  "$HOME/Library/Preferences/$bundle_id.plist"
        rm -rf "$HOME/Library/Saved Application State/$bundle_id.savedState"
        defaults delete "$bundle_id" >/dev/null 2>&1 || true
    fi

    # Drop the Automation (Music/Spotify) permission entries so a reinstall asks again.
    tccutil reset AppleEvents "$bundle_id" >/dev/null 2>&1 || true
done

if [ -z "${KEEP_DATA:-}" ]; then
    say "Removed cached lyrics, artwork and settings."
    killall cfprefsd >/dev/null 2>&1 || true
fi

printf '\n\033[1;32m✓ Lyrette removed.\033[0m\n'
printf '  If it still shows under System Settings → General → Login Items, remove it there.\n'
