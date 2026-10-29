cask "coucou" do
  version "0.5.4"
  sha256 "9d9b2d1330b8d3062abdc614018636f1f5daa68831a35e47b273eac5c3435140"

  url "https://github.com/Louis-CFM/coucou/releases/download/v#{version}/Coucou.zip"
  name "Coucou"
  desc "Notch companion that keeps an eye on your AI coding agents"
  homepage "https://github.com/Louis-CFM/coucou"

  # Only the Mac's tags (vX.Y.Z): windows-v…, linux-v… and android-v… are other apps.
  livecheck do
    url :url
    regex(/^v?(\d+(?:\.\d+)+)$/i)
    strategy :github_releases
  end

  # Coucou updates itself from the notch: brew leaves the installed app alone.
  auto_updates true
  depends_on macos: :sequoia

  app "Coucou.app"

  uninstall quit: "fr.louisraille.NotchBuddy"

  zap trash: [
    "~/Library/Application Support/Coucou",
    "~/Library/Application Support/NotchBuddy",
    "~/Library/Preferences/fr.louisraille.NotchBuddy.plist",
  ]
end
