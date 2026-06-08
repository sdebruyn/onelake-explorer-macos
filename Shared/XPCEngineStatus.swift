// XPCEngineStatus.swift
// NSSecureCoding wrapper for engine status passed over XPC.
//
// `OfemClientControlProtocol.getEngineStatus(reply:)` returns one of
// these across the XPC boundary. NSXPCInterface requires all types that
// cross the boundary to conform to NSSecureCoding.
//
// Fields mirror the subset of the old Go-daemon "status" IPC response that
// the menu-bar UI actually displays:
//   - cacheBytes      — deduplicated on-disk blob bytes (Int64)
//   - cacheMaxBytes   — configured LRU ceiling in bytes (Int64)
//   - cacheMaxSizeGB  — ceiling expressed in whole GBs for the Stepper
//   - telemetryEnabled
//   - netMaxUploads   — max parallel uploads per account
//   - netMaxDownloads — max parallel downloads per account
//   - logLevel        — "debug" | "info" | "warn" | "error"
//
// PausedWorkspaceInfo is omitted intentionally: paused-workspace detection
// lives in the sync engine, which is not yet fully wired in 7.3b-1. The
// menu-bar "paused" icon state will be restored in a later phase once the
// Swift sync engine emits workspace-status updates.

import Foundation

@objc public final class XPCEngineStatus: NSObject, NSSecureCoding {
    @objc public static var supportsSecureCoding: Bool { true }

    @objc public let cacheBytes: Int64
    @objc public let cacheMaxBytes: Int64
    @objc public let cacheMaxSizeGB: Int
    @objc public let telemetryEnabled: Bool
    @objc public let netMaxUploads: Int
    @objc public let netMaxDownloads: Int
    @objc public let logLevel: String

    // MARK: - Init

    @objc public init(
        cacheBytes: Int64,
        cacheMaxBytes: Int64,
        cacheMaxSizeGB: Int,
        telemetryEnabled: Bool,
        netMaxUploads: Int,
        netMaxDownloads: Int,
        logLevel: String
    ) {
        self.cacheBytes = cacheBytes
        self.cacheMaxBytes = cacheMaxBytes
        self.cacheMaxSizeGB = cacheMaxSizeGB
        self.telemetryEnabled = telemetryEnabled
        self.netMaxUploads = netMaxUploads
        self.netMaxDownloads = netMaxDownloads
        self.logLevel = logLevel
        super.init()
    }

    // MARK: - NSSecureCoding

    private enum Keys: String {
        case cacheBytes, cacheMaxBytes, cacheMaxSizeGB
        case telemetryEnabled
        case netMaxUploads, netMaxDownloads
        case logLevel
    }

    @objc public func encode(with coder: NSCoder) {
        coder.encode(cacheBytes, forKey: Keys.cacheBytes.rawValue)
        coder.encode(cacheMaxBytes, forKey: Keys.cacheMaxBytes.rawValue)
        coder.encode(cacheMaxSizeGB, forKey: Keys.cacheMaxSizeGB.rawValue)
        coder.encode(telemetryEnabled, forKey: Keys.telemetryEnabled.rawValue)
        coder.encode(netMaxUploads, forKey: Keys.netMaxUploads.rawValue)
        coder.encode(netMaxDownloads, forKey: Keys.netMaxDownloads.rawValue)
        coder.encode(logLevel, forKey: Keys.logLevel.rawValue)
    }

    @objc public required init?(coder: NSCoder) {
        cacheBytes = coder.decodeInt64(forKey: Keys.cacheBytes.rawValue)
        cacheMaxBytes = coder.decodeInt64(forKey: Keys.cacheMaxBytes.rawValue)
        cacheMaxSizeGB = coder.decodeInteger(forKey: Keys.cacheMaxSizeGB.rawValue)
        telemetryEnabled = coder.decodeBool(forKey: Keys.telemetryEnabled.rawValue)
        netMaxUploads = coder.decodeInteger(forKey: Keys.netMaxUploads.rawValue)
        netMaxDownloads = coder.decodeInteger(forKey: Keys.netMaxDownloads.rawValue)
        logLevel = (coder.decodeObject(of: NSString.self, forKey: Keys.logLevel.rawValue) as? String) ?? "info"
        super.init()
    }
}
