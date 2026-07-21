# Homebrew Cask for BarBlackout.
#
# This file belongs in your personal tap repo, NOT in the app repo:
#   github.com/aadia1234/homebrew-tap  →  Casks/barblackout.rb
#
# Once it's there, users install with:
#   brew install --cask aadia1234/tap/barblackout
#
# Before committing it, fill in the real sha256 of the released DMG:
#   shasum -a 256 BarBlackout.dmg
# and bump `version` to match the git tag you released.

cask "barblackout" do
  version "1.0.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/aadia1234/BarBlackout/releases/download/v#{version}/BarBlackout.dmg"
  name "BarBlackout"
  desc "Hide the macOS menu bar on a timer and while watching video"
  homepage "https://github.com/aadia1234/BarBlackout"

  depends_on macos: ">= :sonoma"

  app "BarBlackout.app"

  zap trash: [
    "~/Library/Preferences/com.aadi.BarBlackout.plist",
  ]
end
