# frozen_string_literal: true

# Dummy 0.0.0 cask kept for reference only.
#
# The canonical cask is homebrew/Casks/ofem.rb.tmpl — the release workflow
# renders it into sdebruyn/homebrew-ofem as Casks/ofem.rb on every tagged
# release. That rendered cask is what users install via `brew install`.
#
# This file is NOT published or installed by anyone. It exists so that
# `brew tap sdebruyn/ofem` can be validated before the first real release.
# Once a real CalVer tag has shipped, this file serves only as a local
# reference; do not update it to track the template.
cask "ofem" do
  version "0.0.0"
  sha256 :no_check

  url "https://github.com/sdebruyn/onelake-explorer-macos/releases/download/v#{version}/OneLake-#{version}.dmg",
      verified: "github.com/sdebruyn/onelake-explorer-macos/"
  name "OneLake Explorer for macOS"
  desc "Browse Microsoft Fabric OneLake from Finder"
  homepage "https://ofem.debruyn.dev/"

  livecheck do
    url :url
    strategy :github_releases
    regex(/^v(\d+\.\d+\.\d+)$/i)
  end

  auto_updates false
  depends_on macos: :sonoma
  depends_on arch: :arm64

  app "OneLake.app"

  uninstall quit: "dev.debruyn.ofem"

  zap trash: [
    # Each account materialises as its own File Provider domain.
    # Zapped only on explicit `brew uninstall --zap` to avoid data loss.
    "~/Library/CloudStorage/OneLake-*",
    # Host app and FPE are both sandboxed, so their preferences live
    # inside their own containers, not ~/Library/Preferences directly.
    "~/Library/Containers/dev.debruyn.ofem",
    "~/Library/Containers/dev.debruyn.ofem.fileprovider",
    "~/Library/Group Containers/6D79CUWZ4J.group.dev.debruyn.ofem",
  ]
end
