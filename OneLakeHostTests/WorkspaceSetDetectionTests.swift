// WorkspaceSetDetectionTests.swift
// Unit tests for the workspace-set signature and change-detection logic
// used by ChangeWatcher to decide when to remount a File Provider domain.
//
// All tests operate on the pure `workspaceSignature(_:)` function and on
// MetadataRecord values.  No NSFileProviderManager, CacheStore, or network
// calls are made.

import OfemKit
import XCTest

final class WorkspaceSetDetectionTests: XCTestCase {
    // MARK: - Helpers

    private func record(path: String, name: String) -> MetadataRecord {
        MetadataRecord(
            accountAlias: "test",
            workspaceID: "__workspaces__",
            itemID: "__workspaces__",
            path: path,
            parentPath: "",
            name: name,
            isDir: true
        )
    }

    // MARK: - workspaceSignature: empty set

    func testSignature_emptySet_returnsEmptyString() {
        let sig = workspaceSignature([])
        XCTAssertEqual(sig, "")
    }

    // MARK: - workspaceSignature: single workspace

    func testSignature_singleWorkspace() {
        let r = record(path: "ws-guid-1", name: "My Workspace")
        let sig = workspaceSignature([r])
        XCTAssertEqual(sig, "ws-guid-1\tMy Workspace")
    }

    // MARK: - workspaceSignature: order-independent (sorted)

    func testSignature_multipleWorkspaces_sortedByGUID() {
        let a = record(path: "aaa", name: "Alpha")
        let b = record(path: "bbb", name: "Beta")
        let c = record(path: "ccc", name: "Gamma")

        // Pass in reverse order — signature must be identical.
        let sig1 = workspaceSignature([a, b, c])
        let sig2 = workspaceSignature([c, b, a])
        XCTAssertEqual(sig1, sig2, "Signature must be order-independent")
    }

    // MARK: - Add detection

    func testSignatureChange_newWorkspaceAdded_signaturesAreDifferent() {
        let before = [record(path: "ws-1", name: "Workspace 1")]
        let after = [record(path: "ws-1", name: "Workspace 1"),
                     record(path: "ws-2", name: "Workspace 2")]

        let sigBefore = workspaceSignature(before)
        let sigAfter = workspaceSignature(after)
        XCTAssertNotEqual(sigBefore, sigAfter,
                          "Signature must change when a workspace is added")
    }

    // MARK: - Remove detection

    func testSignatureChange_workspaceRemoved_signaturesAreDifferent() {
        let before = [record(path: "ws-1", name: "WS1"),
                      record(path: "ws-2", name: "WS2")]
        let after = [record(path: "ws-1", name: "WS1")]

        let sigBefore = workspaceSignature(before)
        let sigAfter = workspaceSignature(after)
        XCTAssertNotEqual(sigBefore, sigAfter,
                          "Signature must change when a workspace is removed")
    }

    // MARK: - Rename detection

    func testSignatureChange_workspaceRenamed_signaturesAreDifferent() {
        let before = [record(path: "ws-1", name: "Old Name")]
        let after = [record(path: "ws-1", name: "New Name")]

        let sigBefore = workspaceSignature(before)
        let sigAfter = workspaceSignature(after)
        XCTAssertNotEqual(sigBefore, sigAfter,
                          "Signature must change when a workspace is renamed")
    }

    // MARK: - Unchanged set does not trigger remount

    func testSignatureUnchanged_sameSet_signaturesAreEqual() {
        let set1 = [record(path: "ws-a", name: "Alpha"),
                    record(path: "ws-b", name: "Beta")]
        let set2 = [record(path: "ws-b", name: "Beta"),
                    record(path: "ws-a", name: "Alpha")]

        XCTAssertEqual(workspaceSignature(set1), workspaceSignature(set2),
                       "Identical workspace sets with different order must produce equal signatures")
    }

    // MARK: - GUID swap is detected (same names, different GUIDs)

    func testSignatureChange_guidSwap_signaturesAreDifferent() {
        // Same display names, different GUIDs (workspace was deleted & re-created).
        let before = [record(path: "guid-old", name: "Finance")]
        let after = [record(path: "guid-new", name: "Finance")]

        XCTAssertNotEqual(workspaceSignature(before), workspaceSignature(after),
                          "GUID change must be detected even when the display name is the same")
    }
}
