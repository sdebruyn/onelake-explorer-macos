package auth

// EntraClientID is the Microsoft Entra App Registration client ID
// embedded into OFEM builds. This is the real multi-tenant public-client
// registration owned by Sam Debruyn (display name
// "OneLake Explorer for macOS"), with http://localhost as the
// redirect URI and "Allow public client flows" enabled. The delegated
// API permission is Azure Storage / user_impersonation.
const EntraClientID = "939b4a06-cc18-49eb-9674-a1fc041489f6"

// OneLakeScopes is the delegated scope for OneLake ADLS Gen2 DFS file
// I/O (audience https://storage.azure.com/). Used by the OneLake client.
var OneLakeScopes = []string{"https://storage.azure.com/user_impersonation"}

// FabricScopes are the delegated scopes for the Microsoft Fabric REST
// API (workspace + item discovery). The Fabric REST API authenticates
// against the Power BI Service resource, so the token audience is
// https://analysis.windows.net/powerbi/api — which api.fabric.microsoft.com
// accepts. These delegated permissions (Workspace.Read.All, Item.Read.All
// on the Power BI Service) must be granted on the OFEM app registration.
//
// OFEM uses Fabric REST for read-only discovery only; all file I/O goes
// through OneLake DFS, so no ReadWrite scope is requested here.
var FabricScopes = []string{
	"https://analysis.windows.net/powerbi/api/Workspace.Read.All",
	"https://analysis.windows.net/powerbi/api/Item.Read.All",
}

// LoginScopes is what interactive / device-code sign-in requests. It is
// deliberately a SINGLE resource (OneLake / storage): the Microsoft
// Entra v2 endpoint rejects an interactive request whose scopes span
// more than one resource with AADSTS28000. The Fabric (Power BI)
// resource token is acquired silently afterwards via TokenForScopes —
// the Fabric delegated permissions are admin-consented on the app
// registration, so MSAL mints that token from the same refresh token
// without a second interactive prompt.
//
// (If a tenant has not admin-consented the Fabric permissions, the first
// Fabric silent acquisition returns consent_required; surfacing an
// interactive re-consent for that case is a Phase 2 refinement.)
var LoginScopes = append([]string{}, OneLakeScopes...)

// Scopes is retained for callers that have not migrated to the
// audience-specific variants.
//
// Deprecated: use OneLakeScopes or FabricScopes explicitly. It equals
// OneLakeScopes and will be removed once all call sites migrate.
var Scopes = append([]string{}, OneLakeScopes...)

// AuthorityHostPublicCloud is the public-cloud Microsoft Entra authority
// host. Sovereign clouds (US Gov, China, Germany) are out of scope for
// MVP; see docs/auth.md.
const AuthorityHostPublicCloud = "https://login.microsoftonline.com"

// TenantHintCommon is a tenant placeholder that lets Microsoft Entra
// route a sign-in to the user's home tenant. Used when the caller does
// not know the tenant up front. See docs/auth.md.
const TenantHintCommon = "organizations"
