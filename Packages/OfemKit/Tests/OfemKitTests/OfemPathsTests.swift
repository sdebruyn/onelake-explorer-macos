import Foundation
import Testing
@testable import OfemKit

// MARK: - OfemPathsTests

@Suite("OfemPaths")
struct OfemPathsTests {
    // MARK: - Root init

    @Test("explicit root: all paths are descendants of root")
    func explicitRootDescendants() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "ofem-paths-test-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        let paths = OfemPaths(root: tmp)

        let allPaths: [(String, URL)] = [
            ("configFile", paths.configFile),
            ("cacheDir", paths.cacheDir),
            ("logDir", paths.logDir),
            ("tokensDir", paths.tokensDir),
        ]

        for (name, url) in allPaths {
            #expect(
                url.path(percentEncoded: false).hasPrefix(tmp.path(percentEncoded: false) + "/"),
                "\(name) must be a descendant of configDir (root)"
            )
        }
    }

    @Test("configDir matches explicit root")
    func configDirIsRoot() {
        let root = URL(filePath: "/tmp/test-root")
        let paths = OfemPaths(root: root)
        #expect(paths.configDir == root)
    }

    @Test("configFile is root/config.toml")
    func configFileIsRootConfigToml() {
        let root = URL(filePath: "/tmp/test-root")
        let paths = OfemPaths(root: root)
        let expected = root.appending(path: "config.toml", directoryHint: .notDirectory)
        #expect(paths.configFile == expected)
    }

    @Test("cacheDir is root/cache")
    func cacheDirIsRootCache() {
        let root = URL(filePath: "/tmp/test-root")
        let paths = OfemPaths(root: root)
        let expected = root.appending(path: "cache", directoryHint: .isDirectory)
        #expect(paths.cacheDir == expected)
    }

    @Test("logDir is root/log")
    func logDirIsRootLog() {
        let root = URL(filePath: "/tmp/test-root")
        let paths = OfemPaths(root: root)
        let expected = root.appending(path: "log", directoryHint: .isDirectory)
        #expect(paths.logDir == expected)
    }

    @Test("tokensDir is root/tokens")
    func tokensDirIsRootTokens() {
        let root = URL(filePath: "/tmp/test-root")
        let paths = OfemPaths(root: root)
        let expected = root.appending(path: "tokens", directoryHint: .isDirectory)
        #expect(paths.tokensDir == expected)
    }

    // MARK: - Constants

    @Test("appGroupIdentifier contains teamID and bundleID")
    func appGroupIdentifierFormat() {
        #expect(OfemPaths.appGroupIdentifier.contains(OfemPaths.teamID))
        #expect(OfemPaths.appGroupIdentifier.contains(OfemPaths.bundleID))
        #expect(OfemPaths.appGroupIdentifier.hasPrefix(OfemPaths.teamID + ".group."))
    }

    @Test("teamID is correct Apple Developer team")
    func teamIDValue() {
        #expect(OfemPaths.teamID == "6D79CUWZ4J")
    }

    @Test("bundleID is correct reverse-DNS identifier")
    func bundleIDValue() {
        #expect(OfemPaths.bundleID == "dev.debruyn.ofem")
    }

    @Test("appGroupIdentifier matches Go GroupID constant")
    func appGroupIdentifierMatchesGoConst() {
        // Go: GroupID = "6D79CUWZ4J.group.dev.debruyn.ofem"
        #expect(OfemPaths.appGroupIdentifier == "6D79CUWZ4J.group.dev.debruyn.ofem")
    }

    // MARK: - Default init (outside sandbox / unit test environment)

    @Test("default init resolves to a non-empty configDir")
    func defaultInitNonEmpty() {
        // This test runs outside the App Group sandbox, so the fallback path
        // ($HOME/Library/Group Containers/<GroupID>/) is used.
        let paths = OfemPaths()
        #expect(!paths.configDir.path(percentEncoded: false).isEmpty)
    }

    @Test("default init resolves configDir to Library/Group Containers/<GroupID>/")
    func defaultInitConfigDirContainsGroupID() {
        let paths = OfemPaths()
        let configDirPath = paths.configDir.path(percentEncoded: false)
        #expect(configDirPath.contains(OfemPaths.appGroupIdentifier))
        #expect(configDirPath.contains("Group Containers"))
    }

    @Test("default init: no legacy macOS locations appear in paths")
    func defaultInitNoLegacyPaths() {
        let paths = OfemPaths()
        let legacyFragments = ["Application Support", "Library/Caches", "Library/Logs"]

        for fragment in legacyFragments {
            #expect(
                !paths.configDir.path(percentEncoded: false).contains(fragment),
                "configDir must not contain legacy location '\(fragment)'"
            )
        }
    }
}
