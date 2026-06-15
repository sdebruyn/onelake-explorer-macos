// XPCPausedWorkspace.swift
// NSSecureCoding wrapper for one paused-workspace entry passed over XPC.
//
// `XPCEngineStatus.pausedWorkspaces` carries an array of these when the
// menu-bar host asks `getEngineStatus`. The host converts each entry into
// a `PausedWorkspaceInfo` for display.
//
// Fields:
//   - accountAlias  — short alias identifying the OFEM account (e.g. "work").
//   - workspaceID   — Fabric workspace GUID.
//   - reason        — short machine string (e.g. "capacity_paused"). Empty
//                     when reason is unknown.
//   - detectedAtSec — Unix seconds when the pause was first detected.
//                     0 means "unknown".
//
// Decode policy (xpc-04): every string field is required. init?(coder:)
// returns nil if any field is absent or the wrong type, so a partial or
// corrupt archive fails loudly instead of producing an object with silent
// empty-string defaults that mask protocol drift.

import Foundation

/// `@unchecked Sendable` is safe here: all stored properties are `let` (immutable
/// after init) and NSObject's retain/release is thread-safe. The type is built on
/// the FPE side and consumed on the host side without mutation (xpc-05).
@objc public final class XPCPausedWorkspace: NSObject, NSSecureCoding, @unchecked Sendable {
    @objc public static var supportsSecureCoding: Bool { true }

    @objc public let accountAlias: String
    @objc public let workspaceID: String
    @objc public let reason: String
    /// Unix seconds (Double) when the pause was first detected. 0 = unknown.
    @objc public let detectedAtSec: Double

    // MARK: - Init

    @objc public init(
        accountAlias: String,
        workspaceID: String,
        reason: String,
        detectedAtSec: Double
    ) {
        self.accountAlias = accountAlias
        self.workspaceID = workspaceID
        self.reason = reason
        self.detectedAtSec = detectedAtSec
        super.init()
    }

    // MARK: - NSSecureCoding

    private enum Keys: String {
        case accountAlias, workspaceID, reason, detectedAtSec
    }

    @objc public func encode(with coder: NSCoder) {
        coder.encode(accountAlias, forKey: Keys.accountAlias.rawValue)
        coder.encode(workspaceID, forKey: Keys.workspaceID.rawValue)
        coder.encode(reason, forKey: Keys.reason.rawValue)
        coder.encode(detectedAtSec, forKey: Keys.detectedAtSec.rawValue)
    }

    @objc public required init?(coder: NSCoder) {
        // All string fields are required: return nil if any is absent or the wrong
        // type so a partial archive fails loudly rather than producing an object with
        // silent empty-string defaults (xpc-04). `detectedAtSec` decodes as Double;
        // a missing key returns 0.0, which is the documented "unknown" sentinel.
        guard
            let accountAlias = coder.decodeObject(of: NSString.self, forKey: Keys.accountAlias.rawValue) as? String,
            let workspaceID  = coder.decodeObject(of: NSString.self, forKey: Keys.workspaceID.rawValue)  as? String,
            let reason       = coder.decodeObject(of: NSString.self, forKey: Keys.reason.rawValue)       as? String
        else { return nil }
        self.accountAlias  = accountAlias
        self.workspaceID   = workspaceID
        self.reason        = reason
        self.detectedAtSec = coder.decodeDouble(forKey: Keys.detectedAtSec.rawValue)
        super.init()
    }
}
