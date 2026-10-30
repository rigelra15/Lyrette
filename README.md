# LyricBar

<p align="center">
  <img src="LyricBar Rounded.png" width="128" alt="LyricBar" style="border-radius: 24px">
</p>

A lightweight macOS menu bar app that displays **synchronized lyrics** for the currently playing song from Apple Music or Spotify.

## Features

- **Real-time lyric sync** — displays the current lyric line in your menu bar
- **Album artwork** — shows the current song's cover in the menu bar and popover
- **Apple Music & Spotify** — auto-detects playing song from either app
- **Synced scrolling** — full lyrics window with auto-scroll to the current line
- **LRCLIB integration** — fetches timestamped `.lrc` lyrics automatically
- **Offline cache** — caches fetched lyrics locally for instant recall
- **Menu bar only** — no dock icon, no clutter
- **Launch at Login** — optional toggle in menu
- **Dynamic access status** — shows checkmark when app is authorized

## Requirements

- macOS 26 (Sequoia) or later
- Apple Music and/or Spotify desktop app installed
- Automation permission granted (prompted on first launch)

## Installation

1. Download `LyricBar.*.dmg` from the [latest release](https://github.com/rigelra15/LyricBar/releases/latest)
2. Open the DMG and drag **LyricBar** into `/Applications`
3. The app isn't code-signed, so macOS will block it. Run this in Terminal:
   ```bash
   xattr -cr /Applications/LyricBar.app
   ```
   (Or right-click the app → **Open** → **Open Anyway**)
4. Launch LyricBar, approve the automation dialogs for Music/Spotify
5. Play a song — lyrics sync to the menu bar

**Build from source:** `git clone` → open `.xcodeproj` in Xcode → ⌘R.

**Menu Bar Items:**

| Item | Description |
|------|-------------|
| Now Playing | Current lyric/title with a compact album cover when music is playing |
| Music/Spotify Access | Request or verify automation permission |
| Show Full Lyrics | Opens a scrollable lyrics window |
| Clear Lyrics Cache | Clears cached LRC files |
| Launch at Login | Toggle auto-start with macOS |
| About LyricBar | App info and version |

## How It Works

1. **Detection** — AppleScript polls Apple Music / Spotify for current track info (title, artist, playback position)
2. **Fetch** — Queries [LRCLIB](https://lrclib.net) API for synced lyrics and Apple's music search for album artwork
3. **Parse** — Parses `.lrc` timestamp format
4. **Sync** — Matches playback position to the correct lyric line
5. **Display** — Shows the current line and compact album cover in the menu bar; the popover includes the full song card and controls

## Project Structure

```
LyricBar/
├── LyricBar/
│   ├── LyricBarApp.swift      # App entry, menu bar UI, lyrics/about windows
│   ├── LyricTicker.swift       # Core logic: detection, fetching, caching, sync
│   ├── ContentView.swift       # Menu bar label and polished popover UI
│   └── Assets.xcassets/        # App icon and logo
├── LyricBar.xcodeproj/         # Xcode project
└── .gitignore
```

## Contributing

Open an issue or PR — contributions welcome.

## Acknowledgments

- [LRCLIB](https://lrclib.net) — open-source lyrics API
- Apple Music & Spotify for AppleScript support

## License

[MIT](LICENSE) — free to use, modify, and distribute.

## Author

Made by [@rigelra](https://github.com/rigelra)
