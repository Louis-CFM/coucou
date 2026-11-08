cask "nexisland" do
  version "1.0.0"
  sha256 :no_check

  url "https://github.com/Snzy09/NexIsland/releases/download/v#{version}/NexIsland.zip"
  name "NexIsland"
  desc "Notch companion that keeps an eye on your AI coding agents with Splash the dolphin"
  homepage "https://github.com/Snzy09/NexIsland"

  livecheck do
    url :url
    regex(/^v?(\d+(?:\.\d+)+)$/i)
    strategy :github_releases
  end

  auto_updates true
  depends_on macos: :sequoia

  app "NexIsland.app"

  uninstall quit: "com.nexsz.nexisland"

  zap trash: [
    "~/Library/Application Support/NexIsland",
    "~/Library/Preferences/com.nexsz.nexisland.plist",
  ]
end
