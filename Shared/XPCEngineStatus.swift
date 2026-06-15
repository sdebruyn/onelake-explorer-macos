// XPCEngineStatus.swift
// NSSecureCoding wrapper for engine status passed over XPC.
//
// `OfemClientControlProtocol.getEngineStatus(reply:)` returns one of
// these across the XPC boundary. NSXPCInterface requires all types that
// cross the boundary to conform to NSSecureCoding.
//
// Fields shown by the menu-bar UI:
// - cacheBytes — deduplicated on-disk blob bytes (Int64)
// - cacheMaxBytes — configured LRU ceiling in bytes (Int64)
// - cacheMaxSizeGB — ceiling expressed in whole GBs for the Stepper
// - telemetryEnabled
// - netMaxUploads — max parallel uploads per account
// - netMaxDownloads — max parallel downloads per account
// - logLevel — "debug" | "info" | "warn" | "error"
// - pausedWorkspaces — workspaces whose Fabric capacity is currently paused;
// empty array = no workspaces paused.
//
// Decode policy (xpc-04): logLevel is a required string field; init?(coder:)
// returns nil when it is absent or the wrong type. This is a stricter contract
// than the previous `?? "info"` fallback, which masked protocol drift by
// silently substituting a plausible-but-wrong default. Callers that archive
// an XPCEngineStatus must always encode logLevel.

import Foundation

/// `@unchecked Sendable` is safe here: all stored properties are `let` (immutable
/// after init) and NSObject's retain/release is thread-safe. The type is built on
/// the FPE side inside a Task and consumed on the host's MainActor (xpc-05).
@objc public final class XPCEngineStatus: NSObject, NSSecureCoding, @unchecked Sendable {
    @objc public static var supportsSecureCoding: Bool { true }

    @objc public let cacheBytes: Int64
    @objc public let cacheMaxBytes: Int64
    @objc public let cacheMaxSizeGB: Int
    @objc public let telemetryEnabled: Bool
    @objc public let netMaxUploads: Int
    @objc public let netMaxDownloads: Int
    @objc public let logLevel: String
    /// Workspaces whose Fabric capacity is currently paused. Empty when none.
    @objc public let pausedWorkspaces: [XPCPausedWorkspace]

    // MARK: - Init

    @objc public init(
        cacheBytes: Int64,
        cacheMaxBytes: Int64,
        cacheMaxSizeGB: Int,
        telemetryEnabled: Bool,
        netMaxUploads: Int,
        netMaxDownloads: Int,
        logLevel: String,
        pausedWorkspaces: [XPCPausedWorkspace] = []
    ) {
        self.cacheBytes = cacheBytes
        self.cacheMaxBytes = cacheMaxBytes
        self.cacheMaxSizeGB = cacheMaxSizeGB
        self.telemetryEnabled = telemetryEnabled
        self.netMaxUploads = netMaxUploads
        self.netMaxDownloads = netMaxDownloads
        self.logLevel = logLevel
        self.pausedWorkspaces = pausedWorkspaces
        super.init()
    }

    // MARK: - NSSecureCoding

    private enum Keys: String {
        case cacheBytes, cacheMaxBytes, cacheMaxSizeGB
        case telemetryEnabled
        case netMaxUploads, netMaxDownloads
        case logLevel
        case pausedWorkspaces
    }

    @objc public func encode(with coder: NSCoder) {
        coder.encode(cacheBytes, forKey: Keys.cacheBytes.rawValue)
        coder.encode(cacheMaxBytes, forKey: Keys.cacheMaxBytes.rawValue)
        coder.encode(cacheMaxSizeGB, forKey: Keys.cacheMaxSizeGB.rawValue)
        coder.encode(telemetryEnabled, forKey: Keys.telemetryEnabled.rawValue)
        coder.encode(netMaxUploads, forKey: Keys.netMaxUploads.rawValue)
        coder.encode(netMaxDownloads, forKey: Keys.netMaxDownloads.rawValue)
        coder.encode(logLevel, forKey: Keys.logLevel.rawValue)
        coder.encode(pausedWorkspaces as NSArray, forKey: Keys.pausedWorkspaces.rawValue)
    }

    @objc public required init?(coder: NSCoder) {
        // logLevel is a required string field: return nil when absent or wrong
        // type rather than falling back to "info", which would mask protocol
        // drift between host and FPE builds (xpc-04).
        //
        // Numeric fields (Int64, Int, Bool) decode as 0/false when absent; this
        // is unavoidable with NSCoder's primitive decode methods — there is no
        // "contains key" API for primitives in NSSecureCoding. Accept the
        // 0/false sentinel for numeric fields; they are observable in the UI.
        //
        // pausedWorkspaces defaults to [] when absent: an empty list is a valid
        // runtime state (no paused workspaces), so a missing key from an older
        // build is safe here.
        guard let logLevel = coder.decodeObject(of: NSString.self, forKey: Keys.logLevel.rawValue) as? String
        else { return nil }
        cacheBytes       = coder.decodeInt64(forKey: Keys.cacheBytes.rawValue)
        cacheMaxBytes    = coder.decodeInt64(forKey: Keys.cacheMaxBytes.rawValue)
        cacheMaxSizeGB   = coder.decodeInteger(forKey: Keys.cacheMaxSizeGB.rawValue)
        telemetryEnabled = coder.decodeBool(forKey: Keys.telemetryEnabled.rawValue)
        netMaxUploads    = coder.decodeInteger(forKey: Keys.netMaxUploads.rawValue)
        netMaxDownloads  = coder.decodeInteger(forKey: Keys.netMaxDownloads.rawValue)
        self.logLevel    = logLevel
        let decoded = coder.decodeObject(
            of: [NSArray.self, XPCPausedWorkspace.self],
            forKey: Keys.pausedWorkspaces.rawValue
        ) as? [XPCPausedWorkspace]
        pausedWorkspaces = decoded ?? []
        super.init()
    }
}
