// XPCBadgeStatus.swift
// NSSecureCoding wrapper for the slim badge status passed over XPC.
//
// `OfemClientControlProtocol.getBadgeStatus(reply:)` returns one of these
// across the XPC boundary. NSXPCInterface requires all types that cross
// the boundary to conform to NSSecureCoding.
//
// Unlike XPCEngineStatus, this carries no cache/config fields at all — by
// construction there is nothing here for the FPE to populate from a
// blobBytes() scan or a config snapshot. It exists specifically so the
// always-on menu-bar badge poll (needsSignIn + pausedWorkspaces) can skip
// both (#397).
//
// Fields:
// - needsSignIn — true when a recent enumeration failed with notAuthenticated,
//   meaning the account's token can no longer be acquired silently and the user
//   must sign in again.
// - pausedWorkspaces — workspaces whose Fabric capacity is currently paused;
//   empty array = no workspaces paused.

import Foundation

/// Immutable snapshot of badge status carried over the XPC boundary.
///
/// All stored properties are `let`, set once at init and never mutated. NSObject +
/// `@objc` prevent automatic Sendable synthesis, so `@unchecked Sendable` is the
/// correct idiomatic annotation — there is no shared mutable state to guard.
@objc(XPCBadgeStatus) public final class XPCBadgeStatus: NSObject, NSSecureCoding, @unchecked Sendable {
    @objc public static var supportsSecureCoding: Bool {
        true
    }

    @objc public let needsSignIn: Bool
    /// Workspaces whose Fabric capacity is currently paused. Empty when none.
    @objc public let pausedWorkspaces: [XPCPausedWorkspace]

    // MARK: - Init

    @objc public init(
        needsSignIn: Bool,
        pausedWorkspaces: [XPCPausedWorkspace] = []
    ) {
        self.needsSignIn = needsSignIn
        self.pausedWorkspaces = pausedWorkspaces
        super.init()
    }

    // MARK: - NSSecureCoding

    private enum Keys: String {
        case needsSignIn
        case pausedWorkspaces
    }

    @objc public func encode(with coder: NSCoder) {
        coder.encode(needsSignIn, forKey: Keys.needsSignIn.rawValue)
        coder.encode(pausedWorkspaces as NSArray, forKey: Keys.pausedWorkspaces.rawValue)
    }

    @objc public required init?(coder: NSCoder) {
        needsSignIn = coder.decodeBool(forKey: Keys.needsSignIn.rawValue)
        let decoded = coder.decodeObject(
            of: [NSArray.self, XPCPausedWorkspace.self],
            forKey: Keys.pausedWorkspaces.rawValue
        ) as? [XPCPausedWorkspace]
        pausedWorkspaces = decoded ?? []
        super.init()
    }
}
