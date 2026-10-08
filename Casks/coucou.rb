cask "coucou" do
  version "0.2.2"
  sha256 "ba97333aa721500c16823306d057887aaddecb11adfd7626d9a40f6b09f26e89"

  url "https://github.com/Louis-CFM/coucou/releases/download/v#{version}/Coucou.zip"
  name "Coucou"
  desc "Notch companion that keeps an eye on your AI coding agents"
  homepage "https://github.com/Louis-CFM/coucou"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sequoia

  app "Coucou.app"

  uninstall quit: "fr.louisraille.NotchBuddy"

  zap trash: [
    "~/Library/Application Support/NotchBuddy",
    "~/Library/Preferences/fr.louisraille.NotchBuddy.plist",
  ]
end
