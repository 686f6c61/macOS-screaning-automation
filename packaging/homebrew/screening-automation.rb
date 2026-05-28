cask "screening-automation" do
  version "0.3.2"
  sha256 :no_check

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
