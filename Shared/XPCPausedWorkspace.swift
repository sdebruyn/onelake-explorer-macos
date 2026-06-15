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

import Foundation

@objc(XPCPausedWorkspace) public final class XPCPausedWorkspace: NSObject, NSSecureCoding {
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
        accountAlias = (coder.decodeObject(of: NSString.self, forKey: Keys.accountAlias.rawValue) as? String) ?? ""
        workspaceID  = (coder.decodeObject(of: NSString.self, forKey: Keys.workspaceID.rawValue)  as? String) ?? ""
        reason       = (coder.decodeObject(of: NSString.self, forKey: Keys.reason.rawValue)       as? String) ?? ""
        detectedAtSec = coder.decodeDouble(forKey: Keys.detectedAtSec.rawValue)
        super.init()
    }
}
