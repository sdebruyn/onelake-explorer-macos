# Dummy 0.0.0 cask used to validate the tap-install pipeline before the first
# real signed and notarized release of OFEM ships.
#
# The download URL below points at a release asset that does not exist yet —
# `brew install` will 404 until we tag v0.0.0 (or the first real CalVer
# release) on sdebruyn/onelake-explorer-macos. The cask still parses, audits,
# and lets us validate `brew tap` + `brew info` end-to-end.
#
# `sha256 :no_check` is intentional for the dummy. On the first real release
# this becomes the real DMG SHA-256 (goreleaser computes and patches it as
# part of the release pipeline — see docs/packaging-homebrew.md in the main
# repo).
cask "ofem" do
  arch arm: "arm64"

  version "0.0.0"
  sha256 :no_check

  url "https://github.com/sdebruyn/onelake-explorer-macos/releases/download/v#{version}/OneLake-#{version}.dmg"
  name "OneLake"
  desc "Finder integration for Microsoft Fabric OneLake"
  homepage "https://github.com/sdebruyn/onelake-explorer-macos"

  # No releases exist yet for the dummy 0.0.0 cask. Once the first real
  # tag ships on sdebruyn/onelake-explorer-macos, swap this for:
  #   livecheck do
  #     url :url
  #     strategy :github_latest
  #   end
  livecheck do
    skip "No published releases yet — first real CalVer tag is pending"
  end

  depends_on macos: :sonoma
  depends_on arch: :arm64

  app "OneLake.app"
  binary "#{appdir}/OneLake.app/Contents/Resources/bin/ofem"

  uninstall launchctl: "dev.debruyn.ofem",
            quit:      "dev.debruyn.ofem"

  zap trash: [
    "~/Library/Application Support/dev.debruyn.ofem",
    "~/Library/Caches/dev.debruyn.ofem",
    "~/Library/LaunchAgents/dev.debruyn.ofem.plist",
    "~/Library/Logs/OFEM",
    "~/Library/Preferences/dev.debruyn.ofem.plist",
    # ~/OneLake is the user's mount point and may contain pending uploads.
    # Only trashed on explicit `brew uninstall --zap` — never on a plain
    # `brew uninstall`.
    "~/OneLake",
  ]
end
