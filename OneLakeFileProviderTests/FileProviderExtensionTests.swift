// FileProviderExtensionTests.swift
// Tests for FileProviderExtension callback logic.
//
// Uses MockEngineHost to exercise completion-handler wiring, error mapping,
// and cancellation behaviour without a live fileproviderd or OfemEngine.

@preconcurrency import FileProvider
import Foundation
import OfemKit
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

    // MARK: - modifyItem — rename with invalid identifier maps to noSuchItem (fpe-09)

    func testModifyItemRenameInvalidIdentifierMapsToNoSuchItem() async {
        // An item whose identifier is a framework-internal constant
        // (not a valid OFEM path identifier) triggers the parsing guard,
        // which maps to noSuchItem — not a pending field.
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)
        let template = MockFPItem(parentID: NSFileProviderItemIdentifier.rootContainer.rawValue, filename: "renamed.txt")

        var capturedError: (any Error)?
        _ = await withCheckedContinuation { cont in
            _ = ext.modifyItem(
                template,
                baseVersion: NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data()),
                changedFields: .filename,
                contents: nil,
                request: makeRequest()
            ) { _, _, _, err in
                capturedError = err
                cont.resume(returning: ())
            }
        }

        let nsErr = capturedError as NSError?
        XCTAssertNotNil(nsErr, "expected an error for an unparseable item identifier")
        XCTAssertEqual(nsErr?.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(nsErr?.code, NSFileProviderError.noSuchItem.rawValue,
                       "unparseable identifier should map to noSuchItem")
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

    // MARK: - modifyItem — rename while the engine is unavailable leaves fields pending, no error

    /// The rename branch's failure handling deliberately diverges from every
    /// other entry point's classify-and-fail behaviour: on failure it leaves
    /// the changed fields pending (retriable) rather than surfacing an
    /// error. That must ALSO hold when the failure is the engine itself
    /// being unavailable (an invalidated host, a build-error back-off
    /// window, a transient build failure) — an engine hiccup during a
    /// rename must not be reported as a hard error, or the framework would
    /// treat a purely transient condition as a permanent failure instead of
    /// simply retrying.
    func testModifyItemRenameEngineUnavailableLeavesFieldsPendingNoError() async {
        let host = MockEngineHost(alias: "test")
        host.engineResult = .failure(NSFileProviderError(.cannotSynchronize))
        let ext = makeExtension(host: host)
        let itemID = "00000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-000000000002/old.txt"
        let template = MockFPItem(id: itemID, parentID: NSFileProviderItemIdentifier.rootContainer.rawValue, filename: "new.txt")

        var capturedItem: NSFileProviderItem?
        var capturedFields: NSFileProviderItemFields = []
        var capturedError: Error?
        _ = await withCheckedContinuation { cont in
            _ = ext.modifyItem(
                template,
                baseVersion: NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data()),
                changedFields: .filename,
                contents: nil,
                request: makeRequest()
            ) { item, fields, _, err in
                capturedItem = item
                capturedFields = fields
                capturedError = err
                cont.resume(returning: ())
            }
        }

        XCTAssertNil(capturedError, "an engine-unavailable rename must NOT surface as an error")
        XCTAssertNotNil(capturedItem, "the (unrenamed) item should still be handed back while pending")
        XCTAssertTrue(capturedFields.contains(.filename),
                      "the filename field must remain pending so the framework retries the rename")
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

    // MARK: - runFPEOperation — shared classification applies uniformly

    /// `deleteItem` previously hand-rolled its own copy of the "resolve the
    /// engine, classify any failure" scaffolding, now routed through the
    /// shared `runFPEOperation` helper. Combined with
    /// `testItemForEngineUnavailableMapsToCannotSynchronize` above, this
    /// proves the same classification applies uniformly across entry points
    /// that previously had independent (and divergence-prone) copies.
    func testDeleteItemEngineUnavailableMapsToCannotSynchronize() async throws {
        let host = MockEngineHost(alias: "test")
        host.engineResult = .failure(NSFileProviderError(.cannotSynchronize))
        let ext = makeExtension(host: host)
        let itemID = NSFileProviderItemIdentifier("00000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-000000000002/file.txt")

        let result = await withCheckedContinuation { cont in
            _ = ext.deleteItem(
                identifier: itemID,
                baseVersion: NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data()),
                options: [],
                request: makeRequest()
            ) { err in
                cont.resume(returning: err)
            }
        }

        let nsErr = try XCTUnwrap(result as NSError?)
        XCTAssertEqual(nsErr.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(nsErr.code, NSFileProviderError.cannotSynchronize.rawValue)
    }

    /// Same regression guard for `modifyItem`'s metadata-only branch, a third
    /// independent call site of `runFPEOperation` (distinct from `item(for:)`
    /// and `deleteItem` above).
    func testModifyItemMetadataOnlyEngineUnavailableMapsToCannotSynchronize() async throws {
        let host = MockEngineHost(alias: "test")
        host.engineResult = .failure(NSFileProviderError(.cannotSynchronize))
        let ext = makeExtension(host: host)
        let itemID = "00000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-000000000002/file.txt"
        let template = MockFPItem(id: itemID, parentID: NSFileProviderItemIdentifier.rootContainer.rawValue, filename: "file.txt")

        let result = await withCheckedContinuation { cont in
            _ = ext.modifyItem(
                template,
                baseVersion: NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data()),
                changedFields: [.lastUsedDate],
                contents: nil,
                request: makeRequest()
            ) { _, _, _, err in
                cont.resume(returning: err)
            }
        }

        let nsErr = try XCTUnwrap(result as NSError?)
        XCTAssertEqual(nsErr.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(nsErr.code, NSFileProviderError.cannotSynchronize.rawValue)
    }

    // MARK: - invalidate() — sets the host invalidated synchronously

    /// `invalidate()` must mark the engine host invalidated on the SAME
    /// (synchronous) call, before the async shutdown Task is even scheduled —
    /// otherwise an operation racing teardown could still build a fresh
    /// engine after macOS already considers the extension gone.
    func testInvalidateMarksHostInvalidatedSynchronously() {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)

        XCTAssertFalse(host.invalidatedSynchronously, "precondition: not yet invalidated")
        ext.invalidate()
        XCTAssertTrue(
            host.invalidatedSynchronously,
            "invalidate() must set the flag before returning, not only inside the async shutdown Task"
        )
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

    // MARK: - enumerator(for:) — trash gets a real empty enumerator, not the working-set one

    /// OneLake has no trash: `.trashContainer` must route to `OfemTrashEnumerator`,
    /// never to `OfemWorkingSetEnumerator`. Before this was fixed, both sentinels
    /// shared the working-set enumerator, so trash enumeration would trigger a
    /// throttled `listWorkspaces` refresh and report alias-wide cache deltas
    /// under the trash container — behaviour that has nothing to do with trash.
    func testEnumeratorForTrashIsNotWorkingSetAndNeverTouchesEngine() throws {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)

        let enumerator = try ext.enumerator(for: .trashContainer, request: makeRequest())

        // Downcast to the concrete type: it both proves trash gets a real
        // OfemTrashEnumerator (not OfemWorkingSetEnumerator — a different
        // final class, so the two are mutually exclusive) and lets the calls
        // below dispatch statically instead of through the optional-chained
        // NSFileProviderEnumerator protocol requirements.
        let trashEnumerator = try XCTUnwrap(
            enumerator as? OfemTrashEnumerator,
            "trash must get a real empty enumerator, not the working-set one"
        )

        let itemsObserver = SpyEnumerationObserver()
        trashEnumerator.enumerateItems(for: itemsObserver, startingAt: NSFileProviderPage.initialPageSortedByName as NSFileProviderPage)
        XCTAssertTrue(itemsObserver.didEnumerateCalled)
        XCTAssertTrue(itemsObserver.enumeratedItems.isEmpty)
        XCTAssertTrue(itemsObserver.finishEnumeratingCalled)

        let changesObserver = SpyChangeObserver()
        trashEnumerator.enumerateChanges(for: changesObserver, from: encodeSyncAnchor(0))
        XCTAssertTrue(changesObserver.finished)
        XCTAssertFalse(changesObserver.finishedWithError)

        XCTAssertEqual(host.engineCallCount, 0, "trash enumeration must never build/touch the engine")
    }

    /// Regression guard: `.workingSet` must keep vending the real
    /// `OfemWorkingSetEnumerator` (only trash was mis-routed).
    func testEnumeratorForWorkingSetReturnsWorkingSetEnumerator() throws {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)

        let enumerator = try ext.enumerator(for: .workingSet, request: makeRequest())

        XCTAssertTrue(enumerator is OfemWorkingSetEnumerator)
    }

    // MARK: - enumerator(for:) — bad identifier maps to noSuchItem

    /// Before this was fixed, a parse failure let the raw `FPError` escape
    /// `enumerator(for:)` unmapped instead of the `NSFileProviderError(.noSuchItem)`
    /// every other entry point's identifier-parsing guard produces.
    func testEnumeratorForBadIdentifierMapsToNoSuchItem() {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)
        let bad = NSFileProviderItemIdentifier("bad//identifier")

        XCTAssertThrowsError(try ext.enumerator(for: bad, request: makeRequest())) { error in
            let nsErr = error as NSError
            XCTAssertEqual(nsErr.domain, NSFileProviderErrorDomain)
            XCTAssertEqual(nsErr.code, NSFileProviderError.noSuchItem.rawValue)
        }
    }

    // MARK: - createItem — success returns an item (M7 happy path)

    func testCreateItemSuccessReturnsItem() async {
        let host = MockEngineHost(alias: "test")
        let wsID = "00000000-0000-0000-0000-000000000001"
        let itemID = "00000000-0000-0000-0000-000000000002"
        let expected = DomainItem.synthetic(
            identifier: .path(workspaceID: wsID, itemID: itemID, path: "new.txt"),
            parentIdentifier: .item(workspaceID: wsID, itemID: itemID),
            name: "new.txt",
            isDirectory: false
        )
        host.createOfemItemResult = .success(expected)
        let ext = makeExtension(host: host)
        let template = MockFPItem(parentID: "\(wsID)/\(itemID)", filename: "new.txt")

        var capturedItem: NSFileProviderItem?
        var capturedError: Error?
        _ = await withCheckedContinuation { cont in
            _ = ext.createItem(
                basedOn: template,
                fields: [],
                contents: nil,
                options: [],
                request: makeRequest()
            ) { item, _, _, err in
                capturedItem = item
                capturedError = err
                cont.resume(returning: ())
            }
        }

        XCTAssertNil(capturedError)
        XCTAssertEqual(capturedItem?.filename, "new.txt")
    }

    // MARK: - modifyItem — rename success returns the renamed item, fields empty

    /// A successful rename must NOT leave `.filename` pending, and — since no
    /// other field was changed in this call — must return an EMPTY fields set
    /// (only a co-delivered non-rename field would stay pending).
    func testModifyItemRenameSuccessReturnsRenamedItemFieldsEmpty() async {
        let host = MockEngineHost(alias: "test")
        let wsID = "00000000-0000-0000-0000-000000000001"
        let itemID = "00000000-0000-0000-0000-000000000002"
        let record = MetadataRecord(
            accountAlias: "test",
            workspaceID: wsID,
            itemID: itemID,
            path: "new.txt",
            parentPath: "",
            name: "new.txt",
            isDir: false
        )
        host.renameOfemItemResult = .success(record)
        let ext = makeExtension(host: host)
        let originalIdentifierString = "\(wsID)/\(itemID)/old.txt"
        let template = MockFPItem(
            id: originalIdentifierString,
            parentID: NSFileProviderItemIdentifier.rootContainer.rawValue,
            filename: "new.txt"
        )

        var capturedItem: NSFileProviderItem?
        var capturedFields: NSFileProviderItemFields = []
        var capturedError: Error?
        _ = await withCheckedContinuation { cont in
            _ = ext.modifyItem(
                template,
                baseVersion: NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data()),
                changedFields: .filename,
                contents: nil,
                request: makeRequest()
            ) { item, fields, _, err in
                capturedItem = item
                capturedFields = fields
                capturedError = err
                cont.resume(returning: ())
            }
        }

        XCTAssertNil(capturedError)
        XCTAssertTrue(capturedFields.isEmpty, "no non-rename fields were changed, so nothing should remain pending")
        XCTAssertEqual(capturedItem?.filename, "new.txt")
        XCTAssertEqual(capturedItem?.itemIdentifier.rawValue, originalIdentifierString,
                       "the ORIGINAL identifier must be preserved so the framework registers a metadata change, not delete+add")
    }

    // MARK: - modifyItem — content-bearing success completes with no error

    func testModifyItemContentSuccessCompletesNoError() async throws {
        let host = MockEngineHost(alias: "test")
        let wsID = "00000000-0000-0000-0000-000000000001"
        let itemID = "00000000-0000-0000-0000-000000000002"
        let expected = DomainItem.synthetic(
            identifier: .path(workspaceID: wsID, itemID: itemID, path: "file.txt"),
            parentIdentifier: .item(workspaceID: wsID, itemID: itemID),
            name: "file.txt",
            isDirectory: false
        )
        // putOfemContents does the put AND the post-upload refetch as a single
        // seam call (see FPEEngineHost's doc), so only this one override is
        // needed — resolveItemResult is not consulted on this branch.
        host.putOfemContentsResult = .success(expected)
        let ext = makeExtension(host: host)

        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("hello".utf8).write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let template = MockFPItem(
            id: "\(wsID)/\(itemID)/file.txt",
            parentID: NSFileProviderItemIdentifier.rootContainer.rawValue,
            filename: "file.txt"
        )

        var capturedItem: NSFileProviderItem?
        var capturedError: Error?
        _ = await withCheckedContinuation { cont in
            _ = ext.modifyItem(
                template,
                baseVersion: NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data()),
                changedFields: .contents,
                contents: tmpURL,
                request: makeRequest()
            ) { item, _, _, err in
                capturedItem = item
                capturedError = err
                cont.resume(returning: ())
            }
        }

        XCTAssertNil(capturedError)
        XCTAssertEqual(capturedItem?.filename, "file.txt")
    }

    // MARK: - modifyItem — metadata-only success returns the item

    func testModifyItemMetadataOnlySuccessReturnsItem() async {
        let host = MockEngineHost(alias: "test")
        let wsID = "00000000-0000-0000-0000-000000000001"
        let itemID = "00000000-0000-0000-0000-000000000002"
        let expected = DomainItem.synthetic(
            identifier: .path(workspaceID: wsID, itemID: itemID, path: "file.txt"),
            parentIdentifier: .item(workspaceID: wsID, itemID: itemID),
            name: "file.txt",
            isDirectory: false
        )
        host.resolveItemResult = .success(expected)
        let ext = makeExtension(host: host)
        let template = MockFPItem(
            id: "\(wsID)/\(itemID)/file.txt",
            parentID: NSFileProviderItemIdentifier.rootContainer.rawValue,
            filename: "file.txt"
        )

        var capturedItem: NSFileProviderItem?
        var capturedFields: NSFileProviderItemFields = []
        var capturedError: Error?
        _ = await withCheckedContinuation { cont in
            _ = ext.modifyItem(
                template,
                baseVersion: NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data()),
                changedFields: [.lastUsedDate],
                contents: nil,
                request: makeRequest()
            ) { item, fields, _, err in
                capturedItem = item
                capturedFields = fields
                capturedError = err
                cont.resume(returning: ())
            }
        }

        XCTAssertNil(capturedError)
        XCTAssertTrue(capturedFields.isEmpty)
        XCTAssertEqual(capturedItem?.filename, "file.txt")
    }

    // MARK: - deleteItem — success completes with no error

    func testDeleteItemSuccessCompletesNoError() async {
        let host = MockEngineHost(alias: "test")
        host.deleteOfemItemResult = .success(())
        let ext = makeExtension(host: host)
        let itemID = NSFileProviderItemIdentifier("00000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-000000000002/file.txt")

        let result = await withCheckedContinuation { cont in
            _ = ext.deleteItem(
                identifier: itemID,
                baseVersion: NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data()),
                options: [],
                request: makeRequest()
            ) { err in
                cont.resume(returning: err)
            }
        }

        XCTAssertNil(result as NSError?)
    }

    // MARK: - modifyItem — reparent with co-delivered rename leaves both fields pending

    /// Branch A with `wantsRename` set: the inline `if wantsRename` at the
    /// reparent path must insert `.filename` into `pendingFields` so the
    /// framework also retries the rename once reparent is supported.
    func testModifyItemReparentAndRenameLeavesBothFieldsPending() async {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)
        let template = MockFPItem(
            parentID: NSFileProviderItemIdentifier.rootContainer.rawValue,
            filename: "new.txt"
        )

        var capturedItem: NSFileProviderItem?
        var capturedFields: NSFileProviderItemFields = []
        _ = await withCheckedContinuation { cont in
            _ = ext.modifyItem(
                template,
                baseVersion: NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data()),
                changedFields: [.parentItemIdentifier, .filename],
                contents: nil,
                request: makeRequest()
            ) { item, fields, _, _ in
                capturedItem = item
                capturedFields = fields
                cont.resume(returning: ())
            }
        }

        XCTAssertNotNil(capturedItem)
        XCTAssertTrue(capturedFields.contains(.parentItemIdentifier),
                      ".parentItemIdentifier must remain pending when reparent is not supported")
        XCTAssertTrue(capturedFields.contains(.filename),
                      ".filename must also remain pending when reparent and rename are co-delivered")
    }

    // MARK: - modifyItem — .contents changed but URL nil acknowledges synchronously

    /// Branch D: `changedFields` includes `.contents` but `contents` is nil.
    /// The branch must complete synchronously with `completionHandler(item, [], false, nil)`
    /// and return a zero-unit Progress — no async operation is started.
    func testModifyItemContentsNilAcknowledgesSynchronously() async {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)
        let template = MockFPItem(
            parentID: NSFileProviderItemIdentifier.rootContainer.rawValue,
            filename: "file.txt"
        )

        var capturedItem: NSFileProviderItem?
        var capturedFields: NSFileProviderItemFields = [.filename] // sentinel — must be overwritten with []
        var capturedError: Error?
        _ = await withCheckedContinuation { cont in
            _ = ext.modifyItem(
                template,
                baseVersion: NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data()),
                changedFields: .contents,
                contents: nil,
                request: makeRequest()
            ) { item, fields, _, err in
                capturedItem = item
                capturedFields = fields
                capturedError = err
                cont.resume(returning: ())
            }
        }

        XCTAssertNil(capturedError)
        XCTAssertNotNil(capturedItem, "item must be echoed back on the nil-URL content branch")
        XCTAssertTrue(capturedFields.isEmpty, "nil-URL content branch must acknowledge with no pending fields")
    }

    // MARK: - modifyItem — rename with co-delivered non-rename field leaves non-rename field pending

    /// `nonRenameFields = changedFields.subtracting([.filename])` must be returned
    /// as the pending-fields set on rename success. A co-delivered `.lastUsedDate`
    /// must remain pending while `.filename` must NOT remain pending after a
    /// successful rename.
    func testModifyItemRenameWithCoDeliveredFieldLeavesNonRenameFieldPending() async {
        let host = MockEngineHost(alias: "test")
        let wsID = "00000000-0000-0000-0000-000000000001"
        let itemID = "00000000-0000-0000-0000-000000000002"
        let record = MetadataRecord(
            accountAlias: "test",
            workspaceID: wsID,
            itemID: itemID,
            path: "new.txt",
            parentPath: "",
            name: "new.txt",
            isDir: false
        )
        host.renameOfemItemResult = .success(record)
        let ext = makeExtension(host: host)
        let originalIdentifierString = "\(wsID)/\(itemID)/old.txt"
        let template = MockFPItem(
            id: originalIdentifierString,
            parentID: NSFileProviderItemIdentifier.rootContainer.rawValue,
            filename: "new.txt"
        )

        var capturedFields: NSFileProviderItemFields = []
        var capturedError: Error?
        _ = await withCheckedContinuation { cont in
            _ = ext.modifyItem(
                template,
                baseVersion: NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data()),
                changedFields: [.filename, .lastUsedDate],
                contents: nil,
                request: makeRequest()
            ) { _, fields, _, err in
                capturedFields = fields
                capturedError = err
                cont.resume(returning: ())
            }
        }

        XCTAssertNil(capturedError)
        XCTAssertTrue(capturedFields.contains(.lastUsedDate),
                      ".lastUsedDate must remain pending — it was co-delivered but not applied by the rename")
        XCTAssertFalse(capturedFields.contains(.filename),
                       ".filename must NOT remain pending after a successful rename")
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
        self.itemIdentifier = NSFileProviderItemIdentifier(id)
        self.parentItemIdentifier = NSFileProviderItemIdentifier(parentID)
        self.filename = filename
        self.contentType = .plainText
        self.capabilities = [.allowsReading, .allowsWriting]
        self.documentSize = nil
        self.contentModificationDate = nil
        self.itemVersion = NSFileProviderItemVersion(contentVersion: Data("v1".utf8), metadataVersion: Data("mv1".utf8))
        super.init()
    }
}

// Need to import UTType explicitly for MockFPItem
import UniformTypeIdentifiers
