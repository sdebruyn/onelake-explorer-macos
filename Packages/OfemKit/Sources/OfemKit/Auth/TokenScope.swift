import Foundation

// MARK: - TokenScope

/// Type-safe scope-set for MSAL token acquisition.
///
/// OFEM talks to two distinct Azure/Fabric audiences. A token minted for one
/// audience is rejected (401) by the other. `TokenScope` makes the audience
/// choice explicit and prevents accidentally using the wrong token for the
/// wrong endpoint.
public enum TokenScope: Sendable {
    /// Delegated scope for OneLake ADLS Gen2 DFS file I/O.
    ///
    /// Audience: `https://storage.azure.com/`
    /// Used by: all file read/write/list/delete operations.
    case oneLake

    /// Delegated scopes for the Microsoft Fabric REST API (workspace and
    /// item discovery).
    ///
    /// Audience: `https://analysis.windows.net/powerbi/api`
    /// Used by: workspace list and item list at app startup and on refresh.
    case fabric

    // MARK: - Scope strings

    /// The OAuth scope strings to pass to MSAL `acquireToken`.
    public var scopes: [String] {
        switch self {
        case .oneLake:
            return TokenScope.oneLakeScopes
        case .fabric:
            return TokenScope.fabricScopes
        }
    }

    // MARK: - Constants

    /// Delegated scope for OneLake ADLS Gen2 DFS file I/O.
    public static let oneLakeScopes = ["https://storage.azure.com/user_impersonation"]

    /// Delegated scopes for Fabric REST API discovery.
    public static let fabricScopes = [
        "https://analysis.windows.net/powerbi/api/Workspace.Read.All",
        "https://analysis.windows.net/powerbi/api/Item.Read.All",
    ]

    /// Scopes used for the first interactive sign-in browser flow.
    ///
    /// Limited to a SINGLE resource (OneLake / storage). The Microsoft Entra
    /// v2 endpoint rejects an interactive request whose scopes span more than
    /// one resource with AADSTS28000. A second interactive browser flow
    /// targeting ``fabricScopes`` follows immediately after the OneLake login
    /// completes, so the user can consent to the Fabric (Power BI) scopes
    /// themselves — no admin pre-consent is assumed or required.
    public static let loginScopes = oneLakeScopes
}

// MARK: - MSAL constants

/// Microsoft Entra App Registration client ID embedded into OFEM builds.
///
/// This is the project's multi-tenant public-client registration
/// ("OneLake Explorer for macOS") with `msauth.dev.debruyn.ofem://auth` as the
/// redirect URI and "Allow public client flows" enabled. The delegated API
/// permission is Azure Storage / user_impersonation.
public let ofemEntraClientID = "939b4a06-cc18-49eb-9674-a1fc041489f6"

/// The public-cloud Microsoft Entra authority host.
///
/// Sovereign clouds (US Gov, China, Germany) are out of scope for MVP.
public let entraAuthorityHost = "https://login.microsoftonline.com"

/// Tenant placeholder that lets Microsoft Entra route a sign-in to the
/// user's home tenant when the tenant is not known up front.
public let entraTenantHintCommon = "organizations"
