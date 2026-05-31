// PausedWorkspaceInfoTests.swift
// Unit tests for the PausedWorkspaceInfo wire type, covering the two Date
// fields that were absent before the Go→Swift field drift was fixed.
//
// These tests use a local JSONDecoder with .iso8601 strategy, mirroring
// what CoreBridge.decoder now does after the fix.

import Foundation
import XCTest

final class PausedWorkspaceInfoTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Full payload — both detectedAt and probedAt present.
    func testDecodesAllFields() throws {
        let json = """
        {
            "accountAlias": "contoso",
            "workspaceId": "ws-abc-123",
            "reason": "capacity paused",
            "detectedAt": "2026-05-31T10:00:00Z",
            "probedAt": "2026-05-31T10:05:00Z"
        }
        """.data(using: .utf8)!

        let info = try decoder.decode(PausedWorkspaceInfo.self, from: json)
        XCTAssertEqual(info.accountAlias, "contoso")
        XCTAssertEqual(info.workspaceId, "ws-abc-123")
        XCTAssertEqual(info.reason, "capacity paused")
        XCTAssertNotNil(info.detectedAt)
        XCTAssertNotNil(info.probedAt)

        // Verify the timestamps round-trip to the expected wall-clock values.
        let fmt = ISO8601DateFormatter()
        XCTAssertEqual(fmt.string(from: info.detectedAt), "2026-05-31T10:00:00Z")
        XCTAssertEqual(fmt.string(from: info.probedAt!), "2026-05-31T10:05:00Z")
    }

    /// omitempty payload — probedAt absent (as Go emits when ProbedAt is
    /// the zero time.Time). detectedAt must still decode; probedAt must be nil.
    func testProbedAtIsOptional() throws {
        let json = """
        {
            "accountAlias": "fabrikam",
            "workspaceId": "ws-xyz-456",
            "reason": "capacity paused",
            "detectedAt": "2026-05-31T09:00:00Z"
        }
        """.data(using: .utf8)!

        let info = try decoder.decode(PausedWorkspaceInfo.self, from: json)
        XCTAssertEqual(info.accountAlias, "fabrikam")
        XCTAssertNotNil(info.detectedAt)
        XCTAssertNil(info.probedAt, "probedAt must be nil when the key is absent (omitempty on Go side)")
    }
}
