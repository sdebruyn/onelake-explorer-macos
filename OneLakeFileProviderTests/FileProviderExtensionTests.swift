// FileProviderExtensionTests.swift
// Tests for FileProviderExtension callback logic.
//
// Uses MockEngineHost to exercise completion-handler wiring, error mapping,
// and cancellation behaviour without a live fileproviderd or OfemEngine.

@preconcurrency import FileProvider
import Foundation
import XCTest

final class FileProviderExtensionTests: XCTestCase {
    // MARK: - item(for:) — engine unavailable maps to cannotSynchronize

    func testItemForEngineUnavailableMapsToCannotSynchronize() async throws {
        let host = MockEngineHost(alias: "test")
        host.engineResult = .failure(NSFileProviderError(.cannotSynchronize))

        let ext = makeExtension(host: host)
        let result = await withCheckedContinuation { cont in
            _ = ext.item(for: .rootContainer, request: makeRequest()) { _, err in
                cont.resume(returning: err)
            }
        }

        let nsErr = try XCTUnwrap(result as NSError?)
        XCTAssertEqual(nsErr.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(nsErr.code, NSFileProviderError.cannotSynchronize.rawValue)
    }

    // MARK: - item(for:) — bad identifier maps to noSuchItem

    func testItemForBadIdentifierMapsToNoSuchItem() async throws {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)

        // "bad//identifier" has an empty segment and will fail ItemIdentifierParser.
        let bad = NSFileProviderItemIdentifier("bad//identifier")
        let result = await withCheckedContinuation { cont in
            _ = ext.item(for: bad, request: makeRequest()) { _, err in
                cont.resume(returning: err)
            }
        }

        let nsErr = try XCTUnwrap(result as NSError?)
        XCTAssertEqual(nsErr.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(nsErr.code, NSFileProviderError.noSuchItem.rawValue)
    }

    // MARK: - item(for:) — workingSet returns noSuchItem

    func testItemForWorkingSetReturnsNoSuchItem() async throws {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)

        let result = await withCheckedContinuation { cont in
            _ = ext.item(for: .workingSet, request: makeRequest()) { _, err in
                cont.resume(returning: err)
            }
        }

        let nsErr = try XCTUnwrap(result as NSError?)
        XCTAssertEqual(nsErr.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(nsErr.code, NSFileProviderError.noSuchItem.rawValue)
    }

    // MARK: - createItem — bad parentIdentifier maps to noSuchItem

    func testCreateItemBadParentIdentifier() async throws {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)
        let template = MockFPItem(parentID: "bad//parent", filename: "test.txt")

        let result = await withCheckedContinuation { cont in
            _ = ext.createItem(
                basedOn: template,
                fields: [],
                contents: nil,
                options: [],
                request: makeRequest()
            ) { _, _, _, err in
                cont.resume(returning: err)
            }
        }

        let nsErr = try XCTUnwrap(result as NSError?)
        XCTAssertEqual(nsErr.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(nsErr.code, NSFileProviderError.noSuchItem.rawValue)
    }

    // MARK: - modifyItem — rename leaves .filename pending (fpe-09)

    func testModifyItemRenameLeavesPending() async {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)
        let template = MockFPItem(parentID: NSFileProviderItemIdentifier.rootContainer.rawValue, filename: "renamed.txt")

        var pendingFields: NSFileProviderItemFields = []
        _ = await withCheckedContinuation { cont in
            _ = ext.modifyItem(
                template,
                baseVersion: NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data()),
                changedFields: .filename,
                contents: nil,
                request: makeRequest()
            ) { _, fields, _, _ in
                pendingFields = fields
                cont.resume(returning: ())
            }
        }

        XCTAssertTrue(pendingFields.contains(.filename),
                      ".filename must remain pending when rename is not supported")
    }

    // MARK: - modifyItem — reparent leaves .parentItemIdentifier pending

    func testModifyItemReparentLeavesPending() async {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)
        let template = MockFPItem(parentID: NSFileProviderItemIdentifier.rootContainer.rawValue, filename: "file.txt")

        var pendingFields: NSFileProviderItemFields = []
        _ = await withCheckedContinuation { cont in
            _ = ext.modifyItem(
                template,
                baseVersion: NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data()),
                changedFields: .parentItemIdentifier,
                contents: nil,
                request: makeRequest()
            ) { _, fields, _, _ in
                pendingFields = fields
                cont.resume(returning: ())
            }
        }

        XCTAssertTrue(pendingFields.contains(.parentItemIdentifier),
                      ".parentItemIdentifier must remain pending when reparent is not supported")
    }

    // MARK: - deleteItem — bad identifier maps to noSuchItem

    func testDeleteItemBadIdentifierMapsToNoSuchItem() async throws {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)
        let bad = NSFileProviderItemIdentifier("bad//id")

        let result = await withCheckedContinuation { cont in
            _ = ext.deleteItem(
                identifier: bad,
                baseVersion: NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data()),
                options: [],
                request: makeRequest()
            ) { err in
                cont.resume(returning: err)
            }
        }

        let nsErr = try XCTUnwrap(result as NSError?)
        XCTAssertEqual(nsErr.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(nsErr.code, NSFileProviderError.noSuchItem.rawValue)
    }

    // MARK: - supportedServiceSources — only rootContainer gets the service

    func testSupportedServiceSourcesRootContainer() async throws {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)

        // [any NSFileProviderServiceSource] is @_nonSendable in the SDK.
        // Box it so it can cross the continuation boundary; unbox immediately.
        struct SourcesBox: @unchecked Sendable {
            let value: [any NSFileProviderServiceSource]
        }
        let box: SourcesBox = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SourcesBox, any Error>) in
            _ = ext.supportedServiceSources(for: .rootContainer) { sources, err in
                if let err { cont.resume(throwing: err) }
                else { cont.resume(returning: SourcesBox(value: sources ?? [])) }
            }
        }
        let sources = box.value

        XCTAssertFalse(sources.isEmpty, "rootContainer should expose the control service")
    }

    func testSupportedServiceSourcesNonRootIsEmpty() async throws {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)
        let wsID = NSFileProviderItemIdentifier("00000000-0000-0000-0000-000000000001")

        // [any NSFileProviderServiceSource] is @_nonSendable in the SDK.
        // Box it so it can cross the continuation boundary; unbox immediately.
        struct SourcesBox: @unchecked Sendable {
            let value: [any NSFileProviderServiceSource]
        }
        let box: SourcesBox = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SourcesBox, any Error>) in
            _ = ext.supportedServiceSources(for: wsID) { sources, err in
                if let err { cont.resume(throwing: err) }
                else { cont.resume(returning: SourcesBox(value: sources ?? [])) }
            }
        }
        let sources = box.value

        XCTAssertTrue(sources.isEmpty, "non-rootContainer should expose no services")
    }

    // MARK: - Helpers

    private func makeExtension(host: MockEngineHost) -> FileProviderExtension {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier("ofem.\(host.alias)"),
            displayName: host.alias
        )
        return FileProviderExtension(domain: domain, engineHost: host)
    }

    private func makeRequest() -> NSFileProviderRequest {
        NSFileProviderRequest()
    }
}

// MARK: - MockFPItem

/// Minimal NSFileProviderItem for tests that need a template object.
private final class MockFPItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities
    let documentSize: NSNumber?
    let contentModificationDate: Date?
    let itemVersion: NSFileProviderItemVersion

    init(
        id: String = "NSFileProviderRootContainerItemIdentifier",
        parentID: String,
        filename: String
    ) {
        itemIdentifier = NSFileProviderItemIdentifier(id)
        parentItemIdentifier = NSFileProviderItemIdentifier(parentID)
        self.filename = filename
        contentType = .plainText
        capabilities = [.allowsReading, .allowsWriting]
        documentSize = nil
        contentModificationDate = nil
        itemVersion = NSFileProviderItemVersion(contentVersion: Data("v1".utf8), metadataVersion: Data("mv1".utf8))
        super.init()
    }
}

// Need to import UTType explicitly for MockFPItem
import UniformTypeIdentifiers
