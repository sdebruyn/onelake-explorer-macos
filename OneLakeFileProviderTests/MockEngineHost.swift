// MockEngineHost.swift
// Shared test double for EngineProviding.
//
// Tests that exercise the FPE callback logic (error mapping, cancellation,
// completion-handler wiring) inject this mock instead of a live FPEEngineHost
// so no real OfemEngine, SQLite, or network round-trip is needed.

@preconcurrency import FileProvider
import Foundation
import OfemKit

/// A configurable test double for the `EngineProviding` protocol.
///
/// By default `engine()` throws `NSFileProviderError(.cannotSynchronize)`.
/// Tests override `engineResult` to inject a successful engine or a specific
/// error, and read `engineCallCount` to assert how many times the engine was
/// requested.
final class MockEngineHost: EngineProviding, @unchecked Sendable {
    /// The alias returned to callers.
    let alias: String

    /// The result returned by `engine()`. Defaults to cannotSynchronize.
    var engineResult: Result<OfemEngine, Error> = .failure(NSFileProviderError(.cannotSynchronize))

    /// The error thrown by `configStore()`, or nil to use `configSnapshot`.
    var configStoreError: Error?

    /// Whether the host has been shut down.
    private(set) var isShutDown = false

    /// Whether `reloadEngine()` was called.
    private(set) var didReload = false

    /// Whether `invalidateSynchronously()` was called. Tracked separately
    /// from `isShutDown` so tests can assert it is set on the SAME
    /// (synchronous) call as `invalidate()`, not only once the async
    /// `shutdown()` Task eventually runs.
    private(set) var invalidatedSynchronously = false

    /// Number of times `engine()` was called.
    /// Guarded by a lock so concurrent callers (fpe-10 test) do not data-race.
    private let countLock = NSLock()
    private var _engineCallCount = 0
    var engineCallCount: Int {
        countLock.withLock { _engineCallCount }
    }

    /// Number of times `configStore()` was called. Mirrors `engineCallCount`
    /// so tests can assert a code path never reads a config snapshot (#397 —
    /// e.g. getBadgeStatus, unlike getEngineStatus, must never touch this).
    /// Guarded by the same lock as `engineCallCount`.
    private var _configStoreCallCount = 0
    var configStoreCallCount: Int {
        countLock.withLock { _configStoreCallCount }
    }

    init(alias: String = "test") {
        self.alias = alias
    }

    func engine() async throws -> OfemEngine {
        countLock.withLock { _engineCallCount += 1 }
        return try engineResult.get()
    }

    func existingEngine() -> OfemEngine? {
        if case let .success(e) = engineResult { return e }
        return nil
    }

    func configStore() throws -> OfemConfigStore {
        countLock.withLock { _configStoreCallCount += 1 }
        if let err = configStoreError { throw err }
        // OfemConfigStore() reads from the app-group container, which is fine
        // in tests (defaults to a no-op config if the file is absent).
        return try OfemConfigStore()
    }

    func reloadEngine() async {
        didReload = true
    }

    func shutdown() async {
        isShutDown = true
    }

    func invalidateSynchronously() {
        invalidatedSynchronously = true
    }

    // MARK: - Auth-error tracking

    /// Guards both auth-state fields so concurrent calls from async Tasks are safe.
    private let signInLock = NSLock()
    private var _markedNeedsSignIn = false
    private var _markNeedsSignInCallCount = 0

    /// Whether `markNeedsSignIn()` has been called at least once.
    var markedNeedsSignIn: Bool {
        signInLock.withLock { _markedNeedsSignIn }
    }

    /// The number of times `markNeedsSignIn()` was called.
    var markNeedsSignInCallCount: Int {
        signInLock.withLock { _markNeedsSignInCallCount }
    }

    var needsSignIn: Bool {
        markedNeedsSignIn
    }

    func markNeedsSignIn() {
        signInLock.withLock {
            _markNeedsSignInCallCount += 1
            _markedNeedsSignIn = true
        }
    }

    // MARK: - FPE operation seam (M7)

    /// Per-operation overrides. When set, the corresponding method returns
    /// (or throws) the override directly, without touching `engine()` at
    /// all — this is what lets a happy-path test stub a successful
    /// resolution/create/rename/put/delete without a live `OfemEngine`.
    ///
    /// When `nil`, each method falls through to the same
    /// `engine()`-then-delegate shape as `EngineProviding`'s default
    /// extension implementation, so the existing `engineResult`/
    /// `engineCallCount` plumbing (and every pre-existing failure/pending
    /// test built on it) keeps working unmodified.
    var resolveItemResult: Result<DomainItem, Error>?
    var createOfemItemResult: Result<DomainItem, Error>?
    var renameOfemItemResult: Result<MetadataRecord, Error>?
    var putOfemContentsResult: Result<Void, Error>?
    var deleteOfemItemResult: Result<Void, Error>?

    func resolveItem(identifier: ItemIdentifier, alias: String) async throws -> DomainItem {
        if let override = resolveItemResult { return try override.get() }
        let engine = try await engine()
        return try await ItemResolution.resolveItem(
            identifier: identifier, alias: alias, sync: engine.sync, cache: engine.cache
        )
    }

    func createOfemItem(
        parent: ItemIdentifier,
        filename: String,
        isDirectory: Bool,
        uploadSource: URL?,
        mayAlreadyExist: Bool,
        alias: String
    ) async throws -> DomainItem {
        if let override = createOfemItemResult { return try override.get() }
        let engine = try await engine()
        return try await ItemResolution.createItem(
            parent: parent,
            filename: filename,
            isDirectory: isDirectory,
            uploadSource: uploadSource,
            mayAlreadyExist: mayAlreadyExist,
            alias: alias,
            sync: engine.sync,
            cache: engine.cache
        )
    }

    func renameOfemItem(key: CacheKey, newName: String) async throws -> MetadataRecord {
        if let override = renameOfemItemResult { return try override.get() }
        let engine = try await engine()
        return try await engine.sync.rename(key: key, newName: newName)
    }

    func putOfemContents(key: CacheKey, sourceURL: URL) async throws {
        if let override = putOfemContentsResult {
            try override.get()
            return
        }
        let engine = try await engine()
        try await engine.sync.put(key: key, sourceURL: sourceURL)
    }

    func deleteOfemItem(key: CacheKey) async throws {
        if let override = deleteOfemItemResult {
            try override.get()
            return
        }
        let engine = try await engine()
        try await engine.sync.delete(key: key)
    }
}
