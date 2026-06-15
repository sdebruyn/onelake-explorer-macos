// XPCAccountInfo.swift
// Account metadata produced by the host app's sign-in flow.
//
// XPCAccountInfo is created in `SharedOfemAuth.signIn` (host process) after a
// successful interactive MSAL sign-in and is consumed in the same process by
// `AddAccountCoordinator`. It does NOT cross the NSXPCConnection boundary —
// none of the `OfemClientControlProtocol` methods carry it as a parameter or
// reply value (xpc-10).
//
// The NSSecureCoding conformance is retained for future use (the type is
// `Shared/` so the FPE could receive it if a future protocol method needs it)
// and for symmetry with the other Shared/ payload types. The `@unchecked
// Sendable` conformance makes it safe to pass across actor boundaries in the
// host app (xpc-05).

import Foundation

/// Immutable account metadata produced after a successful sign-in.
///
/// Carries the user-chosen alias, MSAL-resolved username, tenant GUID, and
/// tenant display name. All fields are required; `init?(coder:)` returns nil
/// if any is absent so decoding a partial archive fails loudly.
@objc public final class XPCAccountInfo: NSObject, NSSecureCoding, @unchecked Sendable {
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



