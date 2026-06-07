import Foundation

// MARK: - EntraAuthorityResolver

/// Resolves a Microsoft Entra authority URL from a tenant identifier.
///
/// An authority URL is the base URL that MSAL uses to discover metadata
/// and submit token requests. It is always:
///
///     https://login.microsoftonline.com/<tenantID>
///
/// where `<tenantID>` is either:
///  - a GUID (e.g. `"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"`) for a known
///    tenant; or
///  - `"organizations"` when the tenant is unknown at sign-in time (MSAL
///    routes to the user's home tenant automatically).
///
/// Mirrors `internal/auth/msal.go` — authority building in `DefaultClientFactory`.
public enum EntraAuthorityResolver {
    // MARK: - Public API

    /// Returns the authority URL for the given tenant hint.
    ///
    /// - Parameter tenantHint: A tenant GUID, a verified domain (e.g.
    ///   `"contoso.onmicrosoft.com"`), or `""` / `nil` to use
    ///   ``entraTenantHintCommon` ("organizations").
    /// - Returns: A valid authority URL for MSAL.
    /// - Throws: ``EntraAuthorityError/invalidURL`` if the resulting string
    ///   is not a valid URL (should never happen with well-formed input).
    public static func authority(tenantHint: String? = nil) throws -> URL {
        let tenant = resolvedTenant(tenantHint)
        let urlString = "\(entraAuthorityHost)/\(tenant)"
        guard let url = URL(string: urlString) else {
            throw EntraAuthorityError.invalidURL(urlString)
        }
        return url
    }

    /// Returns the authority URL for a known tenant ID (a GUID).
    ///
    /// Convenience wrapper over ``authority(tenantHint:)`` for call sites
    /// that already have a resolved tenant ID and want to avoid the Optional
    /// unwrapping pattern.
    public static func authority(tenantID: String) throws -> URL {
        guard !tenantID.isEmpty else {
            // Fall back to the common/organizations tenant so the user can
            // pick their home tenant at sign-in time.
            return try authority(tenantHint: nil)
        }
        return try authority(tenantHint: tenantID)
    }

    // MARK: - Private helpers

    private static func resolvedTenant(_ hint: String?) -> String {
        guard let hint, !hint.isEmpty else {
            return entraTenantHintCommon
        }
        return hint
    }
}

// MARK: - EntraAuthorityError

/// Errors thrown by ``EntraAuthorityResolver``.
public enum EntraAuthorityError: Error, CustomStringConvertible {
    case invalidURL(String)

    public var description: String {
        switch self {
        case let .invalidURL(s):
            return "EntraAuthorityResolver: could not build a valid URL from \"\(s)\""
        }
    }
}
