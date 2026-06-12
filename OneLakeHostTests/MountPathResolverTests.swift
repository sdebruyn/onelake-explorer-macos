// MountPathResolverTests.swift
// Unit tests for MountPathResolver — the testable helper that computes
// the on-disk Finder mount URL from an account alias.

import XCTest

final class MountPathResolverTests: XCTestCase {

    func testMountURL_containsAlias() {
        let url = MountPathResolver.mountURL(alias: "work")
        XCTAssertTrue(url.lastPathComponent == "OneLake-work",
                      "Last path component should be OneLake-<alias>: \(url.path)")
    }

    func testMountURL_underCloudStorageDirectory() {
        let url = MountPathResolver.mountURL(alias: "personal")
        // The parent must be the CloudStorage folder.
        let parent = url.deletingLastPathComponent().lastPathComponent
        XCTAssertEqual(parent, "CloudStorage",
                       "Mount URL parent must be CloudStorage: \(url.path)")
    }

    func testMountURL_isDirectory() {
        let url = MountPathResolver.mountURL(alias: "test")
        XCTAssertTrue(url.hasDirectoryPath,
                      "Mount URL should be a directory URL: \(url.absoluteString)")
    }

    func testMountURL_aliasPreservedVerbatim() {
        // Alias may contain hyphens (common) but no slashes.
        let url = MountPathResolver.mountURL(alias: "my-org-2")
        XCTAssertEqual(url.lastPathComponent, "OneLake-my-org-2")
    }

    func testRealHomeDirectory_isAbsolute() {
        let home = MountPathResolver.realHomeDirectory()
        XCTAssertTrue(home.hasPrefix("/"),
                      "Real home directory should be an absolute path: \(home)")
    }

    func testRealHomeDirectory_doesNotContainContainersPath() {
        // In a sandboxed test environment getpwuid may still return the real
        // home on the test runner. We verify it doesn't start with the App
        // Sandbox Containers path that NSHomeDirectory() would return when
        // running sandboxed.
        let home = MountPathResolver.realHomeDirectory()
        XCTAssertFalse(home.contains("/Library/Containers/"),
                       "realHomeDirectory must not point inside the App Sandbox container: \(home)")
    }
}
