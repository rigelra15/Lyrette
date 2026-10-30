cask "lyricbar" do
  version "1.0.23"
  sha256 "fdd7fa2ae0ac638a9e22e9225fa190f8cdc6935b3b194f43d81620653b2da883"

  url "https://github.com/rigelra15/LyricBar/releases/download/v#{version}/LyricBar.#{version}.dmg"
  name "LyricBar"
  desc "Synced lyrics for Apple Music and Spotify in the menu bar"
  homepage "https://github.com/rigelra15/LyricBar"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :tahoe

  app "LyricBar.app"

  # The app isn't notarized; clear quarantine so Gatekeeper doesn't block the first launch.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/LyricBar.app"]
  end

  uninstall quit: "com.rigelra.LyricBar"

  zap trash: [
    "~/Library/Application Support/LyricBarCache",
    "~/Library/Caches/com.rigelra.LyricBar",
    "~/Library/Preferences/com.rigelra.LyricBar.plist",
  ]
end
