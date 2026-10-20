cask "coucou" do
  version "0.5.2"
  sha256 "16596984b9481df8b47519602f399e8149ab743f6e8d54780da5828a9e0fd970"

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
