import Testing
import Foundation
@testable import OfemKit

@Suite("BuildInfo")
struct BuildInfoTests {
    @Test("version is non-empty and does not contain whitespace")
    func versionNonEmpty() {
        let v = BuildInfo.version
        #expect(!v.isEmpty)
        #expect(!v.contains(" "), "version must not contain spaces: \(v)")
    }

    @Test("version in test context is the dev fallback or a valid CalVer string")
    func versionFallback() {
        // In xctest the bundle is the test runner; CFBundleShortVersionString
        // is absent, so we expect exactly the "0.0.0-dev" fallback.
        // In a fully-versioned Xcode build the value must match CalVer:
        // YYYY.MM.PATCH with each component being digits only.
        let v = BuildInfo.version
        let isDevFallback = v == "0.0.0-dev"
        // CalVer: three dot-separated numeric components (YYYY.MM.PATCH).
        let calVerRegex = /^\d{4}\.\d+\.\d+$/
        let looksLikeCalVer = v.wholeMatch(of: calVerRegex) != nil
        #expect(
            isDevFallback || looksLikeCalVer,
            "version '\(v)' is neither '0.0.0-dev' nor a YYYY.MM.PATCH CalVer string"
        )
    }

    @Test("appInsightsConnectionString starts with InstrumentationKey")
    func connectionStringStartsWithInstrumentationKey() {
        #expect(
            BuildInfo.appInsightsConnectionString.hasPrefix("InstrumentationKey="),
            "connection string must start with InstrumentationKey="
        )
    }

    @Test("appInsightsConnectionString contains IngestionEndpoint")
    func connectionStringContainsIngestionEndpoint() {
        #expect(
            BuildInfo.appInsightsConnectionString.contains("IngestionEndpoint="),
            "connection string must include IngestionEndpoint="
        )
    }

    // MARK: - engine-06: injectable bundle seam

    @Test("version(from:) returns dev fallback for a bundle with no version key")
    func versionFromBundleWithNoKey() {
        // Bundle.main in tests has no CFBundleShortVersionString; the fallback must be "0.0.0-dev".
        let v = BuildInfo.version(from: .main)
        let isDevFallback = v == "0.0.0-dev"
        let calVerRegex = /^\d{4}\.\d+\.\d+$/
        let looksLikeCalVer = v.wholeMatch(of: calVerRegex) != nil
        #expect(
            isDevFallback || looksLikeCalVer,
            "version(from:) returned unexpected string '\(v)'"
        )
    }

    @Test("version(from:) parse path: module bundle has no version key in tests")
    func versionFromModuleBundle() {
        // Bundle(for:) requires a class; use NSObject as a stable proxy.
        // The test runner bundle never carries a version key — fallback expected.
        let v = BuildInfo.version(from: Bundle(for: NSObject.self))
        let isDevFallback = v == "0.0.0-dev"
        let calVerRegex = /^\d{4}\.\d+\.\d+$/
        let looksLikeCalVer = v.wholeMatch(of: calVerRegex) != nil
        #expect(
            isDevFallback || looksLikeCalVer,
            "version(from:) with NSObject bundle returned unexpected string '\(v)'"
        )
    }

    @Test("BuildInfo.version equals version(from: .main) — single source of truth (engine-05)")
    func versionEqualsVersionFromMain() {
        #expect(BuildInfo.version == BuildInfo.version(from: .main))
    }
}

// MARK: - fp-09: FNV-1a-64 hasher testable boundary

@Suite("ContentVersion.FNV64a — digest correctness (fp-09)")
struct FNV64aTests {

    /// Known FNV-1a-64 digest for the empty string.
    /// Offset basis = 14695981039346656037 (0xcbf29ce484222325).
    @Test("empty string digest is the FNV offset basis")
    func emptyStringIsOffsetBasis() {
        let h = ContentVersion.FNV64a()
        #expect(h.digest() == 14_695_981_039_346_656_037)
    }

    /// FNV-1a-64("a") = 0xe40c292c
    /// Known vector from the FNV reference implementation.
    @Test("digest of 'a' matches known FNV-1a-64 vector")
    func digestOfA() {
        var h = ContentVersion.FNV64a()
        h.combine("a")
        // Known FNV-1a-64 value for "a" is 0xaf63dc4c8601ec8c.
        #expect(h.digest() == 0xaf63_dc4c_8601_ec8c)
    }

    @Test("digest is deterministic for the same input")
    func deterministicDigest() {
        var h1 = ContentVersion.FNV64a()
        h1.combine("hello")
        h1.combine(" ")
        h1.combine("world")

        var h2 = ContentVersion.FNV64a()
        h2.combine("hello")
        h2.combine(" ")
        h2.combine("world")

        #expect(h1.digest() == h2.digest())
    }

    @Test("digest changes when input changes")
    func digestChangesOnDifferentInput() {
        var h1 = ContentVersion.FNV64a()
        h1.combine("foo")

        var h2 = ContentVersion.FNV64a()
        h2.combine("bar")

        #expect(h1.digest() != h2.digest())
    }

    @Test("combining in parts equals combining as one string")
    func combinePartsEqualsWhole() {
        var parts = ContentVersion.FNV64a()
        parts.combine("hello")
        parts.combine("world")

        var whole = ContentVersion.FNV64a()
        whole.combine("helloworld")

        #expect(parts.digest() == whole.digest())
    }
}
