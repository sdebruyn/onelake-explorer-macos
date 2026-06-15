// XPCAccountInfo.swift
// NSSecureCoding wrapper for account metadata passed over XPC.
//
// NSXPCInterface requires all types crossing the XPC boundary to
// conform to NSSecureCoding. This class wraps the AccountInfo data
// returned by OfemAuth so it can travel over NSXPCConnection.
//
// The encoding keys deliberately match the Go wire format used by
// the existing StatusTypes.AccountInfo Decodable type — same field
// names, so the host app can adapt quickly.

import Foundation

/// NSSecureCoding-conformant account info for XPC transport.
///
/// Used in OfemClientControlProtocol replies that return account data.
@objc public final class XPCAccountInfo: NSObject, NSSecureCoding {
    @objc public static var supportsSecureCoding: Bool { true }

    @objc public let alias: String
    @objc public let username: String
    @objc public let tenantId: String
    @objc public let tenantName: String

    // MARK: - Init

    @objc public init(alias: String, username: String, tenantId: String, tenantName: String) {
        self.alias = alias
        self.username = username
        self.tenantId = tenantId
        self.tenantName = tenantName
        super.init()
    }

    // MARK: - NSSecureCoding

    private enum Keys: String {
        case alias, username, tenantId, tenantName
    }

    @objc public func encode(with coder: NSCoder) {
        coder.encode(alias, forKey: Keys.alias.rawValue)
        coder.encode(username, forKey: Keys.username.rawValue)
        coder.encode(tenantId, forKey: Keys.tenantId.rawValue)
        coder.encode(tenantName, forKey: Keys.tenantName.rawValue)
    }

    @objc public required init?(coder: NSCoder) {
        guard
            let alias = coder.decodeObject(of: NSString.self, forKey: Keys.alias.rawValue) as? String,
            let username = coder.decodeObject(of: NSString.self, forKey: Keys.username.rawValue) as? String,
            let tenantId = coder.decodeObject(of: NSString.self, forKey: Keys.tenantId.rawValue) as? String,
            let tenantName = coder.decodeObject(of: NSString.self, forKey: Keys.tenantName.rawValue) as? String
        else {
            return nil
        }
        self.alias = alias
        self.username = username
        self.tenantId = tenantId
        self.tenantName = tenantName
        super.init()
    }
}



