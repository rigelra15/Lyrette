cask "lyricbar" do
  version "1.0.25"
  sha256 "f547acf8a78d3d7f80e8c35cb7e8cf2d0eecea78ed88c0be1943bb8cd0a8c2bc"

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
