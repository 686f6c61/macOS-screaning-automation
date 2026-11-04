cask "screening-automation" do
  version "0.4.3"
  sha256 "49e21794d7b790ab319f2d7f7f5fea6b2e1fbac33cd948fda7c1297136e6042c"

  url "https://github.com/686f6c61/macOS-screaning-automation/releases/download/v#{version}/Screening-Automation-#{version}-arm64.zip"
  name "Screening Automation"
  desc "Menu bar capture automation for a configured screen region"
  homepage "https://github.com/686f6c61/macOS-screaning-automation"

  auto_updates true

  app "Screening Automation.app"

  zap trash: [
    "~/Library/Logs/ScreeningAutomation",
    "~/Library/Preferences/tech.686f6c61.screening-automation.plist",
  ]
end
