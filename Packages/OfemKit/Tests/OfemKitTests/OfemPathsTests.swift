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

    @Test("appGroupIdentifier has stable value")
    func appGroupIdentifierHasStableValue() {
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

    // MARK: - Path segment names

    @Test("configFile path segment is exactly 'config.toml'")
    func configFileSegment() {
        let root = URL(filePath: "/tmp/test-root")
        let paths = OfemPaths(root: root)
        #expect(paths.configFile.lastPathComponent == "config.toml")
    }

    @Test("cacheDir last path component is 'cache'")
    func cacheDirSegment() {
        let root = URL(filePath: "/tmp/test-root")
        let paths = OfemPaths(root: root)
        #expect(paths.cacheDir.lastPathComponent == "cache")
    }

    @Test("logDir last path component is 'log'")
    func logDirSegment() {
        let root = URL(filePath: "/tmp/test-root")
        let paths = OfemPaths(root: root)
        #expect(paths.logDir.lastPathComponent == "log")
    }

    @Test("tokensDir last path component is 'tokens'")
    func tokensDirSegment() {
        let root = URL(filePath: "/tmp/test-root")
        let paths = OfemPaths(root: root)
        #expect(paths.tokensDir.lastPathComponent == "tokens")
    }

    // MARK: - Path uniqueness

    @Test("all resolved paths are distinct")
    func allPathsAreDistinct() {
        let root = URL(filePath: "/tmp/test-root")
        let paths = OfemPaths(root: root)
        let all = [
            paths.configDir,
            paths.configFile,
            paths.cacheDir,
            paths.logDir,
            paths.tokensDir,
        ]
        // Every URL must be unique within the set.
        #expect(Set(all).count == all.count)
    }

    // MARK: - Parent directory relationships

    @Test("cacheDir parent is configDir")
    func cacheDirParentIsConfigDir() {
        let root = URL(filePath: "/tmp/test-root")
        let paths = OfemPaths(root: root)
        // Compare path components (trailing-slash insensitive: directory URLs
        // carry a trailing slash, configDir does not).
        #expect(paths.cacheDir.deletingLastPathComponent().pathComponents == paths.configDir.pathComponents)
    }

    @Test("logDir parent is configDir")
    func logDirParentIsConfigDir() {
        let root = URL(filePath: "/tmp/test-root")
        let paths = OfemPaths(root: root)
        #expect(paths.logDir.deletingLastPathComponent().pathComponents == paths.configDir.pathComponents)
    }

    @Test("tokensDir parent is configDir")
    func tokensDirParentIsConfigDir() {
        let root = URL(filePath: "/tmp/test-root")
        let paths = OfemPaths(root: root)
        #expect(paths.tokensDir.deletingLastPathComponent().pathComponents == paths.configDir.pathComponents)
    }

    @Test("configFile parent is configDir")
    func configFileParentIsConfigDir() {
        let root = URL(filePath: "/tmp/test-root")
        let paths = OfemPaths(root: root)
        #expect(paths.configFile.deletingLastPathComponent().pathComponents == paths.configDir.pathComponents)
    }

    // MARK: - Different roots produce independent path sets

    @Test("two instances with different roots have no overlapping paths")
    func differentRootsProduceIndependentPaths() {
        let root1 = URL(filePath: "/tmp/ofem-root-a")
        let root2 = URL(filePath: "/tmp/ofem-root-b")
        let p1 = OfemPaths(root: root1)
        let p2 = OfemPaths(root: root2)

        #expect(p1.configDir    != p2.configDir)
        #expect(p1.configFile   != p2.configFile)
        #expect(p1.cacheDir     != p2.cacheDir)
        #expect(p1.logDir       != p2.logDir)
        #expect(p1.tokensDir    != p2.tokensDir)
    }

    // MARK: - Exotic root paths

    @Test("paths with spaces in root are handled correctly")
    func rootWithSpaces() {
        let root = URL(filePath: "/tmp/my test root")
        let paths = OfemPaths(root: root)
        let configFilePath = paths.configFile.path(percentEncoded: false)
        #expect(configFilePath.contains("my test root"))
        #expect(configFilePath.hasSuffix("/config.toml"))
    }

    @Test("paths with Unicode characters in root are handled correctly")
    func rootWithUnicodeCharacters() {
        let root = URL(filePath: "/tmp/öfem-tëst")
        let paths = OfemPaths(root: root)
        let cachePath = paths.cacheDir.path(percentEncoded: false)
        #expect(cachePath.contains("öfem-tëst"))
        #expect(paths.cacheDir.pathComponents.last == "cache")
    }

    // MARK: - Default init structure

    @Test("default init: configFile sits directly under configDir")
    func defaultInitConfigFileUnderConfigDir() {
        let paths = OfemPaths()
        #expect(paths.configFile.deletingLastPathComponent().pathComponents == paths.configDir.pathComponents)
        #expect(paths.configFile.lastPathComponent == "config.toml")
    }

    @Test("default init: cacheDir, logDir, tokensDir are all under configDir")
    func defaultInitSubdirsUnderConfigDir() {
        let paths = OfemPaths()
        #expect(paths.cacheDir.deletingLastPathComponent().pathComponents == paths.configDir.pathComponents)
        #expect(paths.logDir.deletingLastPathComponent().pathComponents == paths.configDir.pathComponents)
        #expect(paths.tokensDir.deletingLastPathComponent().pathComponents == paths.configDir.pathComponents)
    }
}
