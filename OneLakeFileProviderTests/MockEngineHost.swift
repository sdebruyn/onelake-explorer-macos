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
    var configStoreError: Error? = nil

    /// Whether the host has been shut down.
    private(set) var isShutDown = false

    /// Whether `reloadEngine()` was called.
    private(set) var didReload = false

    /// Number of times `engine()` was called.
    /// Guarded by a lock so concurrent callers (fpe-10 test) do not data-race.
    private let countLock = NSLock()
    private var _engineCallCount = 0
    var engineCallCount: Int { countLock.withLock { _engineCallCount } }

    init(alias: String = "test") {
        self.alias = alias
    }

    func engine() async throws -> OfemEngine {
        countLock.withLock { _engineCallCount += 1 }
        return try engineResult.get()
    }

    func existingEngine() -> OfemEngine? {
        if case .success(let e) = engineResult { return e }
        return nil
    }

    func configStore() throws -> OfemConfigStore {
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

    // MARK: - Auth-error tracking

    /// Guards both auth-state fields so concurrent calls from async Tasks are safe.
    private let signInLock = NSLock()
    private var _markedNeedsSignIn = false
    private var _markNeedsSignInCallCount = 0

    /// Whether `markNeedsSignIn()` has been called at least once.
    var markedNeedsSignIn: Bool { signInLock.withLock { _markedNeedsSignIn } }

    /// The number of times `markNeedsSignIn()` was called.
    var markNeedsSignInCallCount: Int { signInLock.withLock { _markNeedsSignInCallCount } }

    var needsSignIn: Bool { markedNeedsSignIn }

    func markNeedsSignIn() {
        signInLock.withLock {
            _markNeedsSignInCallCount += 1
            _markedNeedsSignIn = true
        }
    }
}
