// ErrorMapping.swift
// Translates `BridgeError` values from the cgo layer into the typed
// `NSFileProviderError` the File Provider framework understands.
//
// Where the Go core's error vocabulary lacks an exact Apple
// counterpart (notably `serverBusy`) we pick the nearest match and
// log a warning. The framework is conservative — it retries on
// `.serverUnreachable`, surfaces `.notAuthenticated` to the user
// with a sign-in affordance, and treats `.cannotSynchronize` as a
// non-retryable failure, so the mapping really does affect product
// behaviour.

import FileProvider
import Foundation
import os.log

private let mappingLog = Logger(
    subsystem: "dev.debruyn.ofem.fileprovider",
    category: "error-mapping"
)

extension BridgeError {
    /// Convert to an `NSError` the File Provider framework understands.
    /// Returned as `Error` (the framework's protocol surface) rather
    /// than `NSFileProviderError` so call sites can pass it straight
    /// to their completion handlers.
    var nsFileProviderError: Error {
        switch self {
        case .noSuchItem(let msg):
            mappingLog.debug("BridgeError.noSuchItem -> .noSuchItem: \(msg, privacy: .public)")
            return NSFileProviderError(.noSuchItem)
        case .notAuthenticated(let msg):
            mappingLog.info("BridgeError.notAuthenticated -> .notAuthenticated: \(msg, privacy: .public)")
            return NSFileProviderError(.notAuthenticated)
        case .serverUnreachable(let msg):
            mappingLog.info("BridgeError.serverUnreachable -> .serverUnreachable: \(msg, privacy: .public)")
            return NSFileProviderError(.serverUnreachable)
        case .serverBusy(let msg):
            // No dedicated mapping — `.serverUnreachable` is the
            // nearest the framework offers. macOS will back off and
            // retry, which is exactly what we want for HTTP 429 /
            // 503 responses from Fabric.
            mappingLog.notice(
                "BridgeError.serverBusy -> .serverUnreachable (no exact mapping): \(msg, privacy: .public)"
            )
            return NSFileProviderError(.serverUnreachable)
        case .insufficientQuota(let msg):
            mappingLog.info("BridgeError.insufficientQuota -> .insufficientQuota: \(msg, privacy: .public)")
            return NSFileProviderError(.insufficientQuota)
        case .cannotSynchronize(let msg):
            mappingLog.error("BridgeError.cannotSynchronize -> .cannotSynchronize: \(msg, privacy: .public)")
            return NSFileProviderError(.cannotSynchronize)
        case .decoding(let msg):
            mappingLog.error("BridgeError.decoding -> .cannotSynchronize: \(msg, privacy: .public)")
            return NSFileProviderError(.cannotSynchronize)
        case .nullPointer(let msg):
            mappingLog.error("BridgeError.nullPointer -> .cannotSynchronize: \(msg, privacy: .public)")
            return NSFileProviderError(.cannotSynchronize)
        case .notBootstrapped:
            mappingLog.error("BridgeError.notBootstrapped -> .cannotSynchronize")
            return NSFileProviderError(.cannotSynchronize)
        }
    }
}
