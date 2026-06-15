// XPCStrictDecodeTests.swift
// Tests for strict NSSecureCoding decode behaviour in XPC payload types (xpc-04).
//
// XPCPausedWorkspace and XPCEngineStatus previously coalesced missing string
// fields to "" / "info" with `?? default` fallbacks. A corrupt or partial archive
// then decoded to a structurally-valid-but-wrong object, masking protocol drift.
// The fix returns nil from init?(coder:) for any absent required string field.
//
// XPCAccountInfo already returned nil on missing fields and serves as the
// reference implementation; its behaviour is verified here as a regression guard.

import Foundation
import XCTest

// MARK: - Helpers

/// Builds a raw keyed archive containing only the given key/value pairs.
/// Used to produce partial archives that omit specific fields.
private func rawArchive(_ pairs: [(String, Any)]) throws -> Data {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    for (key, value) in pairs {
        switch value {
        case let s as String:  archiver.encode(s as NSString, forKey: key)
        case let i as Int:     archiver.encode(i, forKey: key)
        case let i64 as Int64: archiver.encode(i64, forKey: key)
        case let b as Bool:    archiver.encode(b, forKey: key)
        case let d as Double:  archiver.encode(d, forKey: key)
        case let a as NSArray: archiver.encode(a, forKey: key)
        default: XCTFail("Unsupported type for key '\(key)'")
        }
    }
    archiver.finishEncoding()
    return archiver.encodedData
}

private func unarchive<T: NSObject & NSSecureCoding>(_ type: T.Type, from data: Data) -> T? {
    // requiresSecureCoding = true mirrors the real XPC decode path:
    // NSXPCConnection always decodes reply objects with secure coding enabled.
    // This means decodeObject(of:forKey:) enforces the allowed-class list and
    // rejects unexpected types — the same constraints the live XPC runtime applies.
    let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data)
    unarchiver?.requiresSecureCoding = true
    return unarchiver.flatMap { T(coder: $0) }
}

// MARK: - XPCPausedWorkspace strict-decode tests

final class XPCPausedWorkspaceStrictDecodeTests: XCTestCase {

    private let fullFields: [(String, Any)] = [
        ("accountAlias",  "work"),
        ("workspaceID",   "ws-uuid"),
        ("reason",        "capacity_paused"),
        ("detectedAtSec", Double(1_700_000_000))
    ]

    func testFullArchiveDecodes() throws {
        let data = try rawArchive(fullFields)
        let obj = try XCTUnwrap(
            unarchive(XPCPausedWorkspace.self, from: data),
            "Full archive should decode successfully"
        )
        XCTAssertEqual(obj.accountAlias, "work")
        XCTAssertEqual(obj.workspaceID,  "ws-uuid")
        XCTAssertEqual(obj.reason,       "capacity_paused")
        XCTAssertEqual(obj.detectedAtSec, 1_700_000_000, accuracy: 0.001)
    }

    func testMissingAccountAliasReturnsNil() throws {
        let fields = fullFields.filter { $0.0 != "accountAlias" }
        let data = try rawArchive(fields)
        XCTAssertNil(
            unarchive(XPCPausedWorkspace.self, from: data),
            "Missing accountAlias must cause init?(coder:) to return nil"
        )
    }

    func testMissingWorkspaceIDReturnsNil() throws {
        let fields = fullFields.filter { $0.0 != "workspaceID" }
        let data = try rawArchive(fields)
        XCTAssertNil(
            unarchive(XPCPausedWorkspace.self, from: data),
            "Missing workspaceID must cause init?(coder:) to return nil"
        )
    }

    func testMissingReasonReturnsNil() throws {
        let fields = fullFields.filter { $0.0 != "reason" }
        let data = try rawArchive(fields)
        XCTAssertNil(
            unarchive(XPCPausedWorkspace.self, from: data),
            "Missing reason must cause init?(coder:) to return nil"
        )
    }

    func testMissingDetectedAtSecDecodesSentinelZero() throws {
        // detectedAtSec is a Double primitive: NSCoder returns 0.0 when absent.
        // 0.0 is the documented "unknown" sentinel, so this is acceptable.
        let fields = fullFields.filter { $0.0 != "detectedAtSec" }
        let data = try rawArchive(fields)
        let obj = try XCTUnwrap(
            unarchive(XPCPausedWorkspace.self, from: data),
            "Missing detectedAtSec should still decode (sentinel 0.0)"
        )
        XCTAssertEqual(obj.detectedAtSec, 0.0, accuracy: 0.001)
    }

    func testEmptyReasonDecodesSuccessfully() throws {
        var fields = fullFields
        // Replace "capacity_paused" with "" — empty reason is valid.
        fields = fields.map { $0.0 == "reason" ? ("reason", "") : $0 }
        let data = try rawArchive(fields)
        let obj = try XCTUnwrap(
            unarchive(XPCPausedWorkspace.self, from: data),
            "Empty reason string should decode successfully"
        )
        XCTAssertEqual(obj.reason, "")
    }
}

// MARK: - XPCEngineStatus strict-decode tests

final class XPCEngineStatusStrictDecodeTests: XCTestCase {

    private let fullFields: [(String, Any)] = [
        ("cacheBytes",       Int64(512)),
        ("cacheMaxBytes",    Int64(1024)),
        ("cacheMaxSizeGB",   Int(1)),
        ("telemetryEnabled", true),
        ("netMaxUploads",    Int(4)),
        ("netMaxDownloads",  Int(8)),
        ("logLevel",         "info"),
        ("pausedWorkspaces", NSArray())
    ]

    func testFullArchiveDecodes() throws {
        let data = try rawArchive(fullFields)
        let obj = try XCTUnwrap(
            unarchive(XPCEngineStatus.self, from: data),
            "Full archive should decode successfully"
        )
        XCTAssertEqual(obj.logLevel, "info")
        XCTAssertEqual(obj.cacheBytes, 512)
        XCTAssertTrue(obj.pausedWorkspaces.isEmpty)
    }

    func testMissingLogLevelReturnsNil() throws {
        // Previous behaviour: fell back to "info". New behaviour: return nil.
        let fields = fullFields.filter { $0.0 != "logLevel" }
        let data = try rawArchive(fields)
        XCTAssertNil(
            unarchive(XPCEngineStatus.self, from: data),
            "Missing logLevel must cause init?(coder:) to return nil (no silent default)"
        )
    }

    func testMissingPausedWorkspacesDecodesEmpty() throws {
        // pausedWorkspaces is nullable / additive — an older FPE that predates
        // the field encodes nothing; the host receives an empty list, which is
        // a valid state (no paused workspaces). This is intentionally lenient.
        let fields = fullFields.filter { $0.0 != "pausedWorkspaces" }
        let data = try rawArchive(fields)
        let obj = try XCTUnwrap(
            unarchive(XPCEngineStatus.self, from: data),
            "Missing pausedWorkspaces should still decode with empty array"
        )
        XCTAssertTrue(obj.pausedWorkspaces.isEmpty)
    }

    func testNumericDefaultsWhenAbsent() throws {
        // Numeric primitives (Int64, Int, Bool) decode as 0/false when absent.
        // This is a limitation of NSCoder's primitive API; the values are
        // observable in the UI but are not wrong in a misleading way.
        let minimalFields: [(String, Any)] = [("logLevel", "warn")]
        let data = try rawArchive(minimalFields)
        let obj = try XCTUnwrap(
            unarchive(XPCEngineStatus.self, from: data)
        )
        XCTAssertEqual(obj.logLevel, "warn")
        XCTAssertEqual(obj.cacheBytes, 0)
        XCTAssertEqual(obj.cacheMaxBytes, 0)
        XCTAssertFalse(obj.telemetryEnabled)
    }

    func testAllLogLevelsDecodeCorrectly() throws {
        for level in ["debug", "info", "warn", "error"] {
            var fields = fullFields
            fields = fields.map { $0.0 == "logLevel" ? ("logLevel", level) : $0 }
            let data = try rawArchive(fields)
            let obj = try XCTUnwrap(
                unarchive(XPCEngineStatus.self, from: data),
                "logLevel '\(level)' should decode successfully"
            )
            XCTAssertEqual(obj.logLevel, level)
        }
    }
}

// MARK: - XPCAccountInfo strict-decode regression tests

final class XPCAccountInfoStrictDecodeRegressionTests: XCTestCase {
    // XPCAccountInfo already returned nil on missing fields.
    // These are regression guards ensuring that behaviour is preserved.

    private let fullFields: [(String, Any)] = [
        ("alias",      "work"),
        ("username",   "ada@example.com"),
        ("tenantId",   "00000000-0000-0000-0000-000000000001"),
        ("tenantName", "Contoso")
    ]

    func testFullArchiveDecodes() throws {
        let data = try rawArchive(fullFields)
        let obj = try XCTUnwrap(unarchive(XPCAccountInfo.self, from: data))
        XCTAssertEqual(obj.alias,      "work")
        XCTAssertEqual(obj.username,   "ada@example.com")
        XCTAssertEqual(obj.tenantId,   "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(obj.tenantName, "Contoso")
    }

    func testMissingAliasReturnsNil() throws {
        let fields = fullFields.filter { $0.0 != "alias" }
        let data = try rawArchive(fields)
        XCTAssertNil(unarchive(XPCAccountInfo.self, from: data))
    }

    func testMissingUsernameReturnsNil() throws {
        let fields = fullFields.filter { $0.0 != "username" }
        let data = try rawArchive(fields)
        XCTAssertNil(unarchive(XPCAccountInfo.self, from: data))
    }

    func testMissingTenantIdReturnsNil() throws {
        let fields = fullFields.filter { $0.0 != "tenantId" }
        let data = try rawArchive(fields)
        XCTAssertNil(unarchive(XPCAccountInfo.self, from: data))
    }

    func testMissingTenantNameReturnsNil() throws {
        let fields = fullFields.filter { $0.0 != "tenantName" }
        let data = try rawArchive(fields)
        XCTAssertNil(unarchive(XPCAccountInfo.self, from: data))
    }
}
