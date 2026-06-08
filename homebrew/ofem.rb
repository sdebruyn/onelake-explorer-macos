# frozen_string_literal: true

# Dummy 0.0.0 cask used to validate the tap-install pipeline before the first
# real signed and notarized release of OFEM ships.
#
# The download URL below points at a release asset that does not exist yet —
# `brew install` will 404 until we tag v0.0.0 (or the first real CalVer
# release) on sdebruyn/onelake-explorer-macos. The cask still parses, audits,
# and lets us validate `brew tap` + `brew info` end-to-end.
#
# `sha256 :no_check` is intentional for the dummy. On the first real release
# this becomes the real DMG SHA-256 (the release workflow's `Update Homebrew
# cask` step computes and substitutes it — see docs/packaging-homebrew.md in
# the main repo).
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

  # Keep these stanzas in lockstep with homebrew/Casks/ofem.rb.tmpl (the
  # template the release workflow renders into the tap). This dummy only
  # validates the tap pipeline, but stale uninstall/zap rules here would
  # mislead anyone reading it.
  uninstall quit: "dev.debruyn.ofem"

  zap trash: [
    "~/Library/Group Containers/6D79CUWZ4J.group.dev.debruyn.ofem",
    "~/Library/Preferences/dev.debruyn.ofem.plist",
    # Each account materialises as its own File Provider domain.
    # Zapped only on explicit `brew uninstall --zap` to avoid data loss.
    "~/Library/CloudStorage/OneLake-*",
  ]
end
