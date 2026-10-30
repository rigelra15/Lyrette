cask "lyricbar" do
  version "1.0.36"
  sha256 "2e66dd80b93db26bde4cee1c41c0c3e0f623fb87e1ebd7e3027066d7a17653c0"

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
