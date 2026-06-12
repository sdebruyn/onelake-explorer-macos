import Foundation

// MARK: - EntraAuthorityResolver

/// Resolves a Microsoft Entra authority URL from a tenant identifier.
///
/// An authority URL is the base URL that MSAL uses to discover metadata
/// and submit token requests. It is always:
///
/// https://login.microsoftonline.com/<tenantID>
///
/// where `<tenantID>` is either:
/// - a GUID (e.g. `"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"`) for a known
///   tenant; or
/// - a DNS-label sequence (e.g. `"contoso.onmicrosoft.com"`) for a verified
///   domain; or
/// - `"organizations"` when the tenant is unknown at sign-in time (MSAL
///   routes to the user's home tenant automatically).
public enum EntraAuthorityResolver {
    // MARK: - Public API

    /// Returns the authority URL for the given tenant hint.
    ///
    /// - Parameter tenantHint: A tenant GUID, a verified domain (e.g.
    ///   `"contoso.onmicrosoft.com"`), or `""` / `nil` to use
    ///   `"organizations"`.
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

    /// Validates a user-supplied tenant hint before it is interpolated into
    /// the authority URL.
    ///
    /// Accepted forms:
    /// - GUID: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` (RFC 4122, any case).
    /// - DNS-label sequence: one or more labels separated by `.`, each
    ///   consisting of ASCII letters, digits, or `-`, starting and ending
    ///   with a letter or digit.
    ///
    /// Rejects hints containing `/`, `?`, `#`, `@`, or other characters that
    ///  would break the authority URL structure (e.g. a pasted full URL like
    ///  `"contoso.com/extra"`) so the error surfaces here with an actionable
    ///  message rather than failing opaquely inside MSAL.
    ///
    /// - Parameter hint: The raw user-supplied string.
    /// - Throws: ``EntraAuthorityError/invalidTenantHint(_:)`` if the hint
    ///   is not a valid GUID or DNS-label sequence.
    public static func validateTenantHint(_ hint: String) throws {
        guard !hint.isEmpty else { return }
        if isGUID(hint) || isDNSLabelSequence(hint) { return }
        throw EntraAuthorityError.invalidTenantHint(hint)
    }

    // MARK: - Private helpers

    private static func resolvedTenant(_ hint: String?) -> String {
        guard let hint, !hint.isEmpty else {
            return entraTenantHintCommon
        }
        return hint
    }

    /// Returns `true` for strings matching the RFC 4122 GUID format
    /// (8-4-4-4-12 hex digits, any case).
    private static func isGUID(_ s: String) -> Bool {
        let pattern = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    /// Returns `true` for DNS-label sequences: one or more labels separated
    /// by `.`, each consisting of ASCII letters, digits, or `-`, and starting
    /// and ending with a letter or digit.
    private static func isDNSLabelSequence(_ s: String) -> Bool {
        let labelPattern = #"[A-Za-z0-9]([A-Za-z0-9\-]*[A-Za-z0-9])?"#
        let pattern = #"^\#(labelPattern)(\.\#(labelPattern))*$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }
}

// MARK: - EntraAuthorityError

/// Errors thrown by ``EntraAuthorityResolver``.
public enum EntraAuthorityError: Error, CustomStringConvertible {
    case invalidURL(String)
    /// The user-supplied tenant hint is not a valid GUID or DNS-label sequence.
    ///
    /// This fires when the hint contains URL-unsafe characters (e.g. `/`,
    /// `?`, `#`) or is an unparseable string, catching mistakes like a pasted
    /// full URL (`"contoso.com/extra"`) before MSAL fails with an opaque error.
    case invalidTenantHint(String)

    public var description: String {
        switch self {
        case let .invalidURL(s):
            return "EntraAuthorityResolver: could not build a valid URL from \"\(s)\""
        case let .invalidTenantHint(hint):
            return "EntraAuthorityResolver: tenant hint \"\(hint)\" is not a valid GUID or domain — expected e.g. \"contoso.onmicrosoft.com\" or a GUID"
        }
    }
}
