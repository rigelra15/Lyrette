cask "lyrette" do
  version "1.0.59"
  sha256 "6b6f9cc8843cfa741369bd3b3d16c8944695d7f77d2d415e34a7b7e6a51e22f9"

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
