// XPCSecureCodingTests.swift
// NSSecureCoding round-trip tests for types that cross the host↔FPE XPC boundary.
//
// A field added to encode(with:) but omitted from init?(coder:) — or a key
// typo — silently decodes to nil/garbage at runtime. These tests catch that
// class of bug without needing an actual XPC connection.

import Foundation
import XCTest

// MARK: - XPCAccountInfo round-trip

final class XPCAccountInfoTests: XCTestCase {

    private func roundTrip(_ obj: XPCAccountInfo) throws -> XPCAccountInfo {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: obj,
            requiringSecureCoding: true
        )
        let result = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: XPCAccountInfo.self,
            from: data
        )
        return try XCTUnwrap(result, "NSKeyedUnarchiver returned nil — check encode/decode key parity")
    }

    func testRoundTripAllFields() throws {
        let original = XPCAccountInfo(
            alias: "work",
            username: "ada@example.com",
            tenantId: "00000000-0000-0000-0000-000000000001",
            tenantName: "Contoso Ltd"
        )
        let decoded = try roundTrip(original)

        XCTAssertEqual(decoded.alias, original.alias)
        XCTAssertEqual(decoded.username, original.username)
        XCTAssertEqual(decoded.tenantId, original.tenantId)
        XCTAssertEqual(decoded.tenantName, original.tenantName)
    }

    func testRoundTripEmptyStrings() throws {
        let original = XPCAccountInfo(alias: "", username: "", tenantId: "", tenantName: "")
        let decoded = try roundTrip(original)

        XCTAssertEqual(decoded.alias, "")
        XCTAssertEqual(decoded.username, "")
        XCTAssertEqual(decoded.tenantId, "")
        XCTAssertEqual(decoded.tenantName, "")
    }

    func testRoundTripUnicodeContent() throws {
        let original = XPCAccountInfo(
            alias: "héros",
            username: "ユーザー@example.jp",
            tenantId: "tenant-unicode",
            tenantName: "会社名"
        )
        let decoded = try roundTrip(original)

        XCTAssertEqual(decoded.alias, original.alias)
        XCTAssertEqual(decoded.username, original.username)
        XCTAssertEqual(decoded.tenantId, original.tenantId)
        XCTAssertEqual(decoded.tenantName, original.tenantName)
    }

    func testSupportsSecureCodingIsTrue() {
        XCTAssertTrue(XPCAccountInfo.supportsSecureCoding)
    }
}

// MARK: - XPCEngineStatus round-trip

final class XPCEngineStatusTests: XCTestCase {

    private func roundTrip(_ obj: XPCEngineStatus) throws -> XPCEngineStatus {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: obj,
            requiringSecureCoding: true
        )
        let result = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: XPCEngineStatus.self,
            from: data
        )
        return try XCTUnwrap(result, "NSKeyedUnarchiver returned nil — check encode/decode key parity")
    }

    func testRoundTripAllNumericFields() throws {
        let original = XPCEngineStatus(
            cacheBytes: 1_234_567_890,
            cacheMaxBytes: 10_737_418_240,
            cacheMaxSizeGB: 10,
            telemetryEnabled: true,
            netMaxUploads: 4,
            netMaxDownloads: 8,
            logLevel: "debug"
        )
        let decoded = try roundTrip(original)

        XCTAssertEqual(decoded.cacheBytes, original.cacheBytes)
        XCTAssertEqual(decoded.cacheMaxBytes, original.cacheMaxBytes)
        XCTAssertEqual(decoded.cacheMaxSizeGB, original.cacheMaxSizeGB)
        XCTAssertEqual(decoded.telemetryEnabled, original.telemetryEnabled)
        XCTAssertEqual(decoded.netMaxUploads, original.netMaxUploads)
        XCTAssertEqual(decoded.netMaxDownloads, original.netMaxDownloads)
        XCTAssertEqual(decoded.logLevel, original.logLevel)
        XCTAssertTrue(decoded.pausedWorkspaces.isEmpty)
    }

    func testRoundTripTelemetryDisabled() throws {
        let original = XPCEngineStatus(
            cacheBytes: 0,
            cacheMaxBytes: 0,
            cacheMaxSizeGB: 0,
            telemetryEnabled: false,
            netMaxUploads: 2,
            netMaxDownloads: 2,
            logLevel: "info"
        )
        let decoded = try roundTrip(original)
        XCTAssertFalse(decoded.telemetryEnabled)
    }

    func testRoundTripWithPausedWorkspaces() throws {
        let pw1 = XPCPausedWorkspace(
            accountAlias: "work",
            workspaceID: "ws-1111",
            reason: "capacity_paused",
            detectedAtSec: 1_700_000_000
        )
        let pw2 = XPCPausedWorkspace(
            accountAlias: "personal",
            workspaceID: "ws-2222",
            reason: "",
            detectedAtSec: 0
        )
        let original = XPCEngineStatus(
            cacheBytes: 512,
            cacheMaxBytes: 1024,
            cacheMaxSizeGB: 1,
            telemetryEnabled: true,
            netMaxUploads: 4,
            netMaxDownloads: 8,
            logLevel: "warn",
            pausedWorkspaces: [pw1, pw2]
        )
        let decoded = try roundTrip(original)

        XCTAssertEqual(decoded.pausedWorkspaces.count, 2)
        XCTAssertEqual(decoded.pausedWorkspaces[0].accountAlias, "work")
        XCTAssertEqual(decoded.pausedWorkspaces[0].workspaceID, "ws-1111")
        XCTAssertEqual(decoded.pausedWorkspaces[0].reason, "capacity_paused")
        XCTAssertEqual(decoded.pausedWorkspaces[0].detectedAtSec, 1_700_000_000, accuracy: 0.001)
        XCTAssertEqual(decoded.pausedWorkspaces[1].accountAlias, "personal")
        XCTAssertEqual(decoded.pausedWorkspaces[1].workspaceID, "ws-2222")
        XCTAssertEqual(decoded.pausedWorkspaces[1].reason, "")
        XCTAssertEqual(decoded.pausedWorkspaces[1].detectedAtSec, 0, accuracy: 0.001)
    }

    func testRoundTripLogLevelInfoDecodes() throws {
        // Normal round-trip: "info" survives encode → decode.
        let original = XPCEngineStatus(
            cacheBytes: 0, cacheMaxBytes: 0, cacheMaxSizeGB: 0,
            telemetryEnabled: false, netMaxUploads: 0, netMaxDownloads: 0,
            logLevel: "info"
        )
        let decoded = try roundTrip(original)
        XCTAssertEqual(decoded.logLevel, "info")
    }

    func testLogLevelFallsBackToInfoWhenKeyMissing() throws {
        // Verify the `?? "info"` fallback in init?(coder:) by building an
        // archive that encodes all XPCEngineStatus fields *except* logLevel.
        // NSKeyedArchiver lets us encode arbitrary key-value pairs, so we can
        // produce such an archive without a custom NSCoding subclass.
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(Int64(0),   forKey: "cacheBytes")
        archiver.encode(Int64(0),   forKey: "cacheMaxBytes")
        archiver.encode(0,          forKey: "cacheMaxSizeGB")
        archiver.encode(false,      forKey: "telemetryEnabled")
        archiver.encode(0,          forKey: "netMaxUploads")
        archiver.encode(0,          forKey: "netMaxDownloads")
        // "logLevel" intentionally omitted to trigger the fallback.
        archiver.encode([] as NSArray, forKey: "pausedWorkspaces")
        archiver.finishEncoding()
        let data = archiver.encodedData

        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = false  // raw key-value archive, not class-rooted
        let decoded = XPCEngineStatus(coder: unarchiver)
        let status = try XCTUnwrap(decoded, "XPCEngineStatus(coder:) returned nil")
        XCTAssertEqual(status.logLevel, "info", "missing logLevel key must fall back to \"info\"")
    }

    func testSupportsSecureCodingIsTrue() {
        XCTAssertTrue(XPCEngineStatus.supportsSecureCoding)
    }
}

// MARK: - XPCPausedWorkspace round-trip

final class XPCPausedWorkspaceTests: XCTestCase {

    private func roundTrip(_ obj: XPCPausedWorkspace) throws -> XPCPausedWorkspace {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: obj,
            requiringSecureCoding: true
        )
        let result = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: XPCPausedWorkspace.self,
            from: data
        )
        return try XCTUnwrap(result, "NSKeyedUnarchiver returned nil — check encode/decode key parity")
    }

    func testRoundTripAllFields() throws {
        let original = XPCPausedWorkspace(
            accountAlias: "work",
            workspaceID: "aaaabbbb-cccc-dddd-eeee-ffffffffffff",
            reason: "capacity_paused",
            detectedAtSec: 1_700_123_456.789
        )
        let decoded = try roundTrip(original)

        XCTAssertEqual(decoded.accountAlias, original.accountAlias)
        XCTAssertEqual(decoded.workspaceID, original.workspaceID)
        XCTAssertEqual(decoded.reason, original.reason)
        XCTAssertEqual(decoded.detectedAtSec, original.detectedAtSec, accuracy: 0.001)
    }

    func testRoundTripEmptyReason() throws {
        let original = XPCPausedWorkspace(
            accountAlias: "alias",
            workspaceID: "ws-id",
            reason: "",
            detectedAtSec: 0
        )
        let decoded = try roundTrip(original)
        XCTAssertEqual(decoded.reason, "")
        XCTAssertEqual(decoded.detectedAtSec, 0, accuracy: 0.001)
    }

    func testSupportsSecureCodingIsTrue() {
        XCTAssertTrue(XPCPausedWorkspace.supportsSecureCoding)
    }
}
