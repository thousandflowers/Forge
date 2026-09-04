# Homebrew cask for Forge.
#
# A cask rather than a formula: Forge ships an app bundle, not a bare
# executable. The command-line tool is the same binary under another name, so
# it is linked rather than installed separately.
#
# To publish, copy this into a tap repository (Casks/forge.rb) and update
# `version` and `sha256` for the release. `Scripts/make_dmg.sh` prints the
# checksum it produced.
cask "forge" do
  version "0.1.0"
  sha256 :no_check # replaced with the DMG's checksum when the tap is published

  url "https://github.com/thousandflowers/Forge/releases/download/v#{version}/Forge-#{version}.dmg",
      verified: "github.com/thousandflowers/Forge/"
  name "Forge"
  desc "Batch file converter using only Apple frameworks"
  homepage "https://github.com/thousandflowers/Forge"

  depends_on macos: ">= :ventura"

  app "Forge.app"

  # The tool and the app are one binary, which decides from argv which to be.
  binary "#{appdir}/Forge.app/Contents/MacOS/Forge", target: "forge"

  # The build is ad-hoc signed until there is a Developer ID, so Gatekeeper
  # quarantines it on first launch.
  caveats do
    <<~EOS
      Forge is not yet notarized. If macOS refuses to open it, right-click the
      app in Applications and choose Open, or run:
        xattr -dr com.apple.quarantine /Applications/Forge.app
    EOS
  end

  zap trash: [
    "~/Library/Application Support/Forge",
  ]
end
