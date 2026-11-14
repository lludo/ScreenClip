# Copy into a personal tap (github.com/lludo/homebrew-tap, path Casks/screenclip.rb).
# Official homebrew-cask will not accept version :latest or sha256 :no_check.
# After the first release, pin a version and paste the SHA256SUMS digest if you want stricter installs.
cask "screenclip" do
  version :latest
  sha256 :no_check

  url "https://github.com/lludo/ScreenClip/releases/latest/download/ScreenClip.dmg"
  name "ScreenClip"
  desc "Capture feedback as you notice it, then keep going"
  homepage "https://github.com/lludo/ScreenClip"

  depends_on macos: ">= :sonoma"

  app "ScreenClip.app"

  zap trash: [
    "~/Library/Application Support/ScreenClip",
    "~/Library/Preferences/com.mirageteam.screenclip.plist",
  ]
end
