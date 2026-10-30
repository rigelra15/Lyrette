cask "lyrette" do
  version "1.0.52"
  sha256 "e43eb802528b239815e3f3488b66cf4688510509cb83c20c3798a6ac4a68e0a8"

  url "https://github.com/rigelra15/Lyrette/releases/download/v#{version}/Lyrette.#{version}.dmg"
  name "Lyrette"
  desc "Synced lyrics for Apple Music and Spotify in the menu bar"
  homepage "https://github.com/rigelra15/Lyrette"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :tahoe

  app "Lyrette.app"

  # The app isn't notarized; clear quarantine so Gatekeeper doesn't block the first launch.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Lyrette.app"]
  end

  uninstall quit: ["com.rigelra.Lyrette", "com.rigelra.LyricBar"]

  # Lyrette was called LyricBar before; zap also clears what that version left behind.
  zap trash: [
    "~/Library/Application Support/LyretteCache",
    "~/Library/Application Support/LyricBarCache",
    "~/Library/Caches/com.rigelra.Lyrette",
    "~/Library/Caches/com.rigelra.LyricBar",
    "~/Library/Preferences/com.rigelra.Lyrette.plist",
    "~/Library/Preferences/com.rigelra.LyricBar.plist",
  ]
end
