// XPCError.swift
// SecureCoding-safe error representation for the host↔FPE XPC boundary.
//
// Custom Swift error types (enum SetConfigError, CacheError, FPError, …) are
// not guaranteed to survive NSSecureCoding across the XPC boundary: a non-NSError
// Swift enum arrives at the remote end as a generic NSError whose domain/code/
// userInfo lose the original case and errorDescription, making it impossible for
// the host to distinguish "unknown key" from "invalid value" from a transport
// failure (xpc-03).
//
// This file defines:
//
//   1. `OfemXPCErrorDomain` — the stable NSError domain for errors that originate
//      inside the FPE and need to survive the XPC boundary.
//
//   2. `OfemXPCErrorCode` — typed integer codes that the host can switch on after
//      it receives an NSError in the XPC reply.
//
//   3. `NSError.ofemXPC(code:message:)` — factory that produces an NSError with
//      the correct domain, code, and a human-readable localizedDescription.
//
//   4. `OfemXPCErrorCode.setConfigError(from:)` — categorises a local Swift error
//      into the nearest XPC-safe code, so the FPE handler can call this before
//      passing any error to a reply block.
//
// Usage on the FPE side (OfemClientControlService):
//
//   reply(NSError.ofemXPC(for: someSwiftError))
//
// Usage on the host side (OfemFPEClient):
//
//   catch let nsError as NSError where nsError.domain == OfemXPCErrorDomain {
//       let code = OfemXPCErrorCode(rawValue: nsError.code)
//       switch code {
//       case .setConfigUnknownKey: …
//       case .setConfigInvalidValue: …
//       default: …
//       }
//   }

import Foundation

// MARK: - Domain

/// Stable NSError domain for errors crossing the host↔FPE XPC boundary.
///
/// All errors produced by `NSError.ofemXPC(…)` carry this domain so the host
/// can reliably distinguish them from NSXPCConnection transport errors (whose
/// domain is `NSCocoaErrorDomain` or `"NSXPCConnectionErrorDomain"`).
public let OfemXPCErrorDomain = "dev.debruyn.ofem.xpc"

// MARK: - Error codes

/// Typed integer codes for `OfemXPCErrorDomain` errors.
///
/// Codes are stable across builds — do NOT reorder or delete values; add new
/// ones at the end. The host switches on these after receiving an NSError with
/// `domain == OfemXPCErrorDomain`.
@objc public enum OfemXPCErrorCode: Int {
    // MARK: setConfig errors (1xx)

    /// The config key passed to `setConfig(key:value:)` is not recognised.
    case setConfigUnknownKey    = 100
    /// The value passed to `setConfig(key:value:)` failed validation for the given key.
    case setConfigInvalidValue  = 101

    // MARK: Internal / unexpected (9xx)

    /// An unexpected or unclassified error occurred in the FPE handler.
    case internalError          = 900
}

// MARK: - NSError factory

public extension NSError {

    /// Creates an NSError in `OfemXPCErrorDomain` with the given code and message.
    ///
    /// The `message` is stored both in `NSLocalizedDescriptionKey` (for human
    /// display) and in the `"OfemMessage"` userInfo key (for programmatic use
    /// when `localizedDescription` is auto-wrapped by the runtime).
    static func ofemXPC(code: OfemXPCErrorCode, message: String) -> NSError {
        NSError(
            domain: OfemXPCErrorDomain,
            code: code.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: message,
                "OfemMessage": message
            ]
        )
    }

    /// Bridges an arbitrary Swift `Error` to a SecureCoding-safe `NSError`
    /// in `OfemXPCErrorDomain`.
    ///
    /// - If `error` is already an `NSError` in `OfemXPCErrorDomain`, it is
    ///   returned as-is (zero overhead on already-bridged errors).
    /// - If `error` is already an `NSError` (e.g. from Foundation/FileManager),
    ///   it is wrapped in `internalError` with its `localizedDescription`.
    /// - Otherwise the error's `localizedDescription` is captured and the code
    ///   is inferred from the error's type name when possible.
    static func ofemXPC(for error: Error) -> NSError {
        // Already a properly-bridged XPC error — pass through.
        let ns = error as NSError
        if ns.domain == OfemXPCErrorDomain {
            return ns
        }

        // Infer the code from the error's string representation so common
        // SetConfigError cases map to the right code without a hard import
        // dependency on the FPE-internal SetConfigError enum.
        //
        // FRAGILE: String(reflecting:) produces a fully-qualified name like
        // "OneLakeFileProvider.SetConfigError". A module rename or type rename
        // silently breaks this heuristic, causing all SetConfigError cases to
        // fall through to .internalError. If SetConfigError ever moves to
        // OfemKit (where Shared/ can import it), switch to a typed check:
        //   if let e = error as? SetConfigError { … }
        let desc = error.localizedDescription
        let typeName = String(reflecting: type(of: error))

        if typeName.contains("SetConfigError") {
            if desc.contains("unknown key") || desc.contains("unknownKey") {
                return ofemXPC(code: .setConfigUnknownKey, message: desc)
            }
            return ofemXPC(code: .setConfigInvalidValue, message: desc)
        }

        return ofemXPC(code: .internalError, message: desc)
    }
}
